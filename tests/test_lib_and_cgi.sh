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
# Drain stdin to catch any caller that fails to isolate POST body via </dev/null
cat >/dev/null 2>&1 || true
printf 'Content-Type: application/json\r\n\r\n'
if [ "\${REQUEST_METHOD:-}" != "GET" ] || [ -n "\${CONTENT_LENGTH:-}" ] || [ -n "\${CONTENT_TYPE:-}" ]; then
    echo '{ "success": false, "error_code": 5300 }'
    exit 0
fi
case "&\$QUERY_STRING&" in
    *"&act=get-nonstop&"*)
        if [ "\$QUERY_STRING" = "act=get-nonstop&sid=valid_admin_sid-1.0~ok" ]; then
            echo '{ "success": true, "nonstop": "none" }'
        else
            echo '{ "success": false, "error_code": 5000 }'
        fi
        ;;
    *)
        echo '{ "success": false, "error_code": 5301 }'
        ;;
esac
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
        MOUNTFIX_WEBMAN_COMMON_SH="${MOUNTFIX_WEBMAN_COMMON_SH:-$REPO_ROOT/webman/scripts/common.sh}" \
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

    # 8d. Valid sid + unknown act=bogus -> valid JSON error with HTTP header, and verifier saw act=get-nonstop
    : > "$AUTH_CALL_LOG"
    raw_bogus=$(run_cgi "$cgi" "sid=valid_admin_sid-1.0~ok&act=bogus")
    body_bogus=$(assert_cgi_json "$raw_bogus" "$cgi_name act=bogus")
    [ "$(cat "$AUTH_CALL_LOG")" = "act=get-nonstop&sid=valid_admin_sid-1.0~ok" ] || \
        fail "$cgi_name did not pass act=get-nonstop&sid=... to ADM_AUTH_CGI: [$(cat "$AUTH_CALL_LOG")]"
    jq -e '.success == false and (.error | length > 0)' >/dev/null <<<"$body_bogus" || \
        fail "$cgi_name act=bogus unexpected body: $body_bogus"
done

# Confirm MOCK_ADM_AUTH returns error_code 5301 when act=get-nonstop is omitted (matching ADM 5.1.5 admin.cgi)
MOCK_NO_ACT_RAW=$(REQUEST_METHOD=GET CONTENT_LENGTH= CONTENT_TYPE= QUERY_STRING="sid=valid_admin_sid-1.0~ok" "$MOCK_ADM_AUTH" </dev/null)
MOCK_NO_ACT_BODY=$(assert_cgi_json "$MOCK_NO_ACT_RAW" "mock_admin.cgi missing act=get-nonstop")
jq -e '.success == false and .error_code == 5301' >/dev/null <<<"$MOCK_NO_ACT_BODY" || \
    fail "mock_admin.cgi missing act=get-nonstop expected error_code 5301, got: $MOCK_NO_ACT_BODY"

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

# 9d. mount.cgi rejects invalid app/target with unified JSON response & guards against empty output
MNT_BAD=$(assert_cgi_json "$(run_cgi "$REPO_ROOT/webman/mount.cgi" "$VALID_SID&act=mount&target=/volume2&app=MountFix")" "mount.cgi MountFix")
jq -e '.success == false and .error == "Invalid app name"' >/dev/null <<<"$MNT_BAD" || \
    fail "mount.cgi MountFix mismatch: $MNT_BAD"

EMPTY_MOUNT_COMMON="$CGI_ENV/empty_mount_common.sh"
cat <<EOF > "$EMPTY_MOUNT_COMMON"
. "$REPO_ROOT/webman/scripts/common.sh"
mount_app() { return 1; }
unmount_app() { return 1; }
EOF
MNT_EMPTY=$(assert_cgi_json "$(MOUNTFIX_WEBMAN_COMMON_SH="$EMPTY_MOUNT_COMMON" run_cgi "$REPO_ROOT/webman/mount.cgi" "$VALID_SID&act=mount&target=/volume2&app=docker-ce")" "mount.cgi empty mount_app output")
jq -e '.success == false and .error == "Mount operation failed"' >/dev/null <<<"$MNT_EMPTY" || \
    fail "mount.cgi empty mount_app fallback mismatch: $MNT_EMPTY"
UMNT_EMPTY=$(assert_cgi_json "$(MOUNTFIX_WEBMAN_COMMON_SH="$EMPTY_MOUNT_COMMON" run_cgi "$REPO_ROOT/webman/mount.cgi" "$VALID_SID&act=unmount&target=/volume2&app=docker-ce")" "mount.cgi empty unmount_app output")
jq -e '.success == false and .error == "Unmount operation failed"' >/dev/null <<<"$UMNT_EMPTY" || \
    fail "mount.cgi empty unmount_app fallback mismatch: $UMNT_EMPTY"

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

# Verify POST body stdin is NOT consumed by require_adm_session() even when REQUEST_METHOD=POST and CONTENT_LENGTH/CONTENT_TYPE are set
POST_PAYLOAD='{"targetVolume":"/volume2","selectedApps":[{"name":"docker-ce"},{"name":"entware","enabled":false}]}'
CFG_POST_RAW=$(
    printf '%s' "$POST_PAYLOAD" | \
        REQUEST_METHOD=POST \
        CONTENT_LENGTH="${#POST_PAYLOAD}" \
        CONTENT_TYPE="application/json" \
        QUERY_STRING="$VALID_SID&act=set" \
        ADM_AUTH_CGI="$MOCK_ADM_AUTH" \
        MOUNTFIX_WEBMAN_COMMON_SH="$REPO_ROOT/webman/scripts/common.sh" \
        MOUNTFIX_LIB_SH="$REPO_ROOT/CONTROL/lib.sh" \
        INSTALLED_APPS_JSON="$INSTALLED_FIXTURE" \
        DIR_VOL1="$CGI_VOL1" \
        VOLUME_ROOT="$CGI_VOL_ROOT" \
        CONFIG_FILE="$CGI_ETC/mountfix.conf" \
        MF_CONFIG_DIR="$CGI_ETC" \
        sh "$REPO_ROOT/webman/config.cgi"
)
CFG_POST_BODY=$(assert_cgi_json "$CFG_POST_RAW" "config.cgi POST set stdin preservation")
jq -e '.success == true and .msg == "Settings saved"' >/dev/null <<<"$CFG_POST_BODY" || \
    fail "config.cgi POST set failed (stdin consumed or env leaked into require_adm_session): $CFG_POST_BODY"
jq -e '. == {"targetVolume":"/volume2","selectedApps":[{"name":"docker-ce"},{"name":"entware","enabled":false}]}' "$CGI_ETC/mountfix.conf" >/dev/null || \
    fail "config.cgi POST set did not persist full POST body: $(cat "$CGI_ETC/mountfix.conf")"

# ---------------------------------------------------------------------------
# 10. resolve_base_block_device: SATA, NVMe, and MMC partition stripping (F13)
# ---------------------------------------------------------------------------
echo "Test 10: resolve_base_block_device handles SATA, NVMe, and MMC devices..."
(
    # shellcheck disable=SC1091
    . "$REPO_ROOT/webman/scripts/common.sh"

    assert_base_dev() {
        local input="$1"
        local expected="$2"
        local actual
        actual=$(resolve_base_block_device "$input")
        [ "$actual" = "$expected" ] || \
            fail "resolve_base_block_device($input): expected [$expected], got [$actual]"
    }

    assert_base_dev "sdd4" "sdd"
    assert_base_dev "sda12" "sda"
    assert_base_dev "nvme0n1p1" "nvme0n1"
    assert_base_dev "nvme1n1p4" "nvme1n1"
    assert_base_dev "nvme0n1" "nvme0n1"
    assert_base_dev "mmcblk0p2" "mmcblk0"
    assert_base_dev "mmcblk0" "mmcblk0"
    assert_base_dev "sda" "sda"
)

# ---------------------------------------------------------------------------
# 11. get_volume_rotational with fake SYS_BLOCK_DIR and PROC_MOUNTS (F13)
# ---------------------------------------------------------------------------
echo "Test 11: get_volume_rotational detects HDD RAID, NVMe RAID, and direct NVMe partitions..."
ROT_ENV="$TMP_DIR/rot_env"
FAKE_SYS_BLOCK="$ROT_ENV/sys_block"
FAKE_PROC_MOUNTS="$ROT_ENV/proc_mounts"
FAKE_VOLS="$ROT_ENV/volumes"

mkdir -p \
    "$FAKE_SYS_BLOCK/md1/slaves" \
    "$FAKE_SYS_BLOCK/sdd/queue" \
    "$FAKE_SYS_BLOCK/md2/slaves" \
    "$FAKE_SYS_BLOCK/nvme0n1/queue" \
    "$FAKE_SYS_BLOCK/nvme1n1/queue" \
    "$FAKE_VOLS/volume1" \
    "$FAKE_VOLS/volume2" \
    "$FAKE_VOLS/volume3"

: > "$FAKE_SYS_BLOCK/md1/slaves/sdd4"
printf '1\n' > "$FAKE_SYS_BLOCK/sdd/queue/rotational"

# Simulate `@` suffix from `ls -F` / symlink indicator on NVMe RAID slave
: > "$FAKE_SYS_BLOCK/md2/slaves/nvme0n1p3@"
printf '0\n' > "$FAKE_SYS_BLOCK/nvme0n1/queue/rotational"

# Direct NVMe partition /dev/nvme1n1p1 has no /sys/block/nvme1n1p1 entry, only base disk /sys/block/nvme1n1
printf '0\n' > "$FAKE_SYS_BLOCK/nvme1n1/queue/rotational"

cat <<EOF > "$FAKE_PROC_MOUNTS"
/dev/md10 /volume10 ext4 rw,relatime 0 0
/dev/md1 /volume1 ext4 rw,relatime 0 0
/dev/md2 $FAKE_VOLS/volume2 btrfs rw,relatime 0 0
/dev/nvme1n1p1 /volume3 ext4 rw,relatime 0 0
EOF

(
    export SYS_BLOCK_DIR="$FAKE_SYS_BLOCK"
    export PROC_MOUNTS="$FAKE_PROC_MOUNTS"
    export VOLUMES_ROOT="$FAKE_VOLS"
    # shellcheck disable=SC1091
    . "$REPO_ROOT/webman/scripts/common.sh"

    # /volume1 -> md1 -> sdd4 -> sdd/queue/rotational=1 (and does not match /volume10)
    rot_v1=$(get_volume_rotational "/volume1")
    [ "$rot_v1" = "1" ] || fail "Expected /volume1 rotational=1 (HDD), got [$rot_v1]"

    # $FAKE_VOLS/volume2 -> md2 -> nvme0n1p3@ -> nvme0n1/queue/rotational=0
    rot_v2=$(get_volume_rotational "$FAKE_VOLS/volume2")
    [ "$rot_v2" = "0" ] || fail "Expected volume2 NVMe RAID rotational=0 (SSD), got [$rot_v2]"

    # /volume3 -> /dev/nvme1n1p1 (no slaves/) -> nvme1n1/queue/rotational=0
    rot_v3=$(get_volume_rotational "/volume3")
    [ "$rot_v3" = "0" ] || fail "Expected /volume3 direct NVMe partition rotational=0 (SSD), got [$rot_v3]"

    # Also works via VOLUMES_ROOT logical fallback ($FAKE_VOLS/volume3 -> /volume3 in PROC_MOUNTS)
    rot_v3_dir=$(get_volume_rotational "$FAKE_VOLS/volume3")
    [ "$rot_v3_dir" = "0" ] || fail "Expected $FAKE_VOLS/volume3 rotational=0 via logical fallback, got [$rot_v3_dir]"

    # Direct device arguments
    [ "$(get_volume_rotational "/dev/nvme1n1p1")" = "0" ] || fail "Expected /dev/nvme1n1p1 rotational=0"
    [ "$(get_volume_rotational "md2")" = "0" ] || fail "Expected md2 rotational=0"
    [ "$(get_volume_rotational "md1")" = "1" ] || fail "Expected md1 rotational=1"
    [ "$(get_volume_rotational "/volume99")" = "1" ] || fail "Expected unknown /volume99 rotational=1 fallback"
)

# ---------------------------------------------------------------------------
# 12. get_volumes_json with wrapped df output, -Ph fallback, and escaping (F13)
# ---------------------------------------------------------------------------
echo "Test 12: get_volumes_json parses wrapped df output, POSIX -Ph fallback, and NVMe SSD flags..."
DF_ENV="$TMP_DIR/df_env"
DF_VOLS="$DF_ENV/vols"
MOCK_DF_WRAP="$DF_ENV/mock_df_wrap.sh"
MOCK_DF_NOP="$DF_ENV/mock_df_no_p.sh"
DF_PROC_MOUNTS="$DF_ENV/proc_mounts"

mkdir -p "$DF_VOLS/volume1" "$DF_VOLS/volume2"

cat <<EOF > "$DF_PROC_MOUNTS"
/dev/md1 $DF_VOLS/volume1 ext4 rw,relatime 0 0
/dev/md2 $DF_VOLS/volume2 btrfs rw,relatime 0 0
EOF

# Mock df #1: accepts -Ph, emits single-line for volume1 and wrapped 2-line for volume2
cat <<'EOF' > "$MOCK_DF_WRAP"
#!/bin/sh
flag="$1"
target="$2"
[ "$flag" = "-Ph" ] || exit 1
echo "Filesystem                Size      Used Available Use% Mounted on"
case "$target" in
    */volume1)
        echo "/dev/md1                  3.6T      1.2T      2.4T  34% /volume1"
        ;;
    */volume2)
        echo "/dev/mapper/vg_nvme_long_device_name"
        echo "                          916G      120G      796G  14% /volume2"
        ;;
esac
EOF
chmod 755 "$MOCK_DF_WRAP"

# Mock df #2: rejects -Ph (simulating BusyBox without -P), falls back to -h with wrapped output + quote in device name
cat <<'EOF' > "$MOCK_DF_NOP"
#!/bin/sh
flag="$1"
target="$2"
if [ "$flag" = "-Ph" ]; then
    echo "df: invalid option -- 'P'" >&2
    exit 1
fi
echo "Filesystem                Size      Used Available Use% Mounted on"
case "$target" in
    */volume1)
        echo '/dev/md"1                 3.6T      1.2T      2.4T  34% /volume1'
        ;;
    */volume2)
        echo "/dev/mapper/vg_nvme_long_device_name"
        echo "                          916G      120G      796G  14% /volume2"
        ;;
esac
EOF
chmod 755 "$MOCK_DF_NOP"

VOLS_JSON_1=$(
    SYS_BLOCK_DIR="$FAKE_SYS_BLOCK" \
    PROC_MOUNTS="$DF_PROC_MOUNTS" \
    VOLUMES_ROOT="$DF_VOLS" \
    DF_BIN="$MOCK_DF_WRAP" \
    sh -c '. "$1/webman/scripts/common.sh" && printf "[%s]\n" "$(get_volumes_json)"' _ "$REPO_ROOT"
)

printf '%s\n' "$VOLS_JSON_1" | jq empty || fail "get_volumes_json (wrapped -Ph) produced invalid JSON: $VOLS_JSON_1"
jq -e '
    length == 2 and
    (.[0] == {
        volume: "/volume1",
        mountPoint: "/dev/md1",
        freeSpace: "2.4T",
        totalSpace: "3.6T",
        usedPercent: "34%",
        isSSD: false
    }) and
    (.[1] == {
        volume: "/volume2",
        mountPoint: "/dev/mapper/vg_nvme_long_device_name",
        freeSpace: "796G",
        totalSpace: "916G",
        usedPercent: "14%",
        isSSD: true
    })
' >/dev/null <<<"$VOLS_JSON_1" || fail "get_volumes_json (wrapped -Ph) mismatch: $VOLS_JSON_1"

VOLS_JSON_2=$(
    SYS_BLOCK_DIR="$FAKE_SYS_BLOCK" \
    PROC_MOUNTS="$DF_PROC_MOUNTS" \
    VOLUMES_ROOT="$DF_VOLS" \
    DF_BIN="$MOCK_DF_NOP" \
    sh -c '. "$1/webman/scripts/common.sh" && printf "[%s]\n" "$(get_volumes_json)"' _ "$REPO_ROOT"
)

printf '%s\n' "$VOLS_JSON_2" | jq empty || fail "get_volumes_json (-h fallback + quote escape) produced invalid JSON: $VOLS_JSON_2"
jq -e '
    length == 2 and
    .[0].volume == "/volume1" and
    .[0].mountPoint == "/dev/md\"1" and
    .[0].isSSD == false and
    .[1].volume == "/volume2" and
    .[1].mountPoint == "/dev/mapper/vg_nvme_long_device_name" and
    .[1].freeSpace == "796G" and
    .[1].totalSpace == "916G" and
    .[1].usedPercent == "14%" and
    .[1].isSSD == true
' >/dev/null <<<"$VOLS_JSON_2" || fail "get_volumes_json (-h fallback) mismatch: $VOLS_JSON_2"

# Verify config.cgi?act=get end-to-end includes the parsed NVMe/HDD volumes
CFG_VOLS_RAW=$(
    SYS_BLOCK_DIR="$FAKE_SYS_BLOCK" \
    PROC_MOUNTS="$DF_PROC_MOUNTS" \
    VOLUMES_ROOT="$DF_VOLS" \
    DF_BIN="$MOCK_DF_WRAP" \
    run_cgi "$REPO_ROOT/webman/config.cgi" "$VALID_SID&act=get"
)
CFG_VOLS_BODY=$(assert_cgi_json "$CFG_VOLS_RAW" "config.cgi volumes integration")
jq -e '
    (.volumes | length == 2) and
    (.volumes[0].volume == "/volume1" and .volumes[0].isSSD == false) and
    (.volumes[1].volume == "/volume2" and .volumes[1].isSSD == true and .volumes[1].freeSpace == "796G")
' >/dev/null <<<"$CFG_VOLS_BODY" || fail "config.cgi volumes integration mismatch: $CFG_VOLS_BODY"

# ---------------------------------------------------------------------------
# 13. F3: mount_app / unmount_app sync boot config & validate.cgi reports mismatch
# ---------------------------------------------------------------------------
echo "Test 13: F3 mount/unmount boot config sync and validate.cgi mismatch reporting..."
F3_ENV="$TMP_DIR/f3_env"
F3_VOL1="$F3_ENV/vol1"
F3_VOL_ROOT="$F3_ENV/volumes"
F3_ETC="$F3_ENV/etc"
MOCK_MOUNT_OK="$F3_ENV/mock_mount.sh"
MOCK_UMOUNT_OK="$F3_ENV/mock_umount.sh"

mkdir -p \
    "$F3_VOL1/.@plugins/AppCentral/docker-ce" \
    "$F3_VOL1/.@plugins/AppCentral/entware" \
    "$F3_VOL_ROOT/volume2/AppCentral/docker-ce" \
    "$F3_VOL_ROOT/volume2/AppCentral/entware" \
    "$F3_ETC"

printf '{"targetVolume":"/volume2","selectedApps":[]}\n' > "$F3_ETC/mountfix.conf"
: > "$F3_ETC/mounts.list"

printf '#!/bin/sh\nexit 0\n' > "$MOCK_MOUNT_OK"
printf '#!/bin/sh\nexit 0\n' > "$MOCK_UMOUNT_OK"
chmod 755 "$MOCK_MOUNT_OK" "$MOCK_UMOUNT_OK"

F3_MNT_OUT=$(
    DIR_VOL1="$F3_VOL1" \
    VOLUME_ROOT="$F3_VOL_ROOT" \
    CONFIG_FILE="$F3_ETC/mountfix.conf" \
    MF_CONFIG_DIR="$F3_ETC" \
    PROC_ROOT="$TMP_DIR/empty_proc_f3" \
    MOUNT_BIN="$MOCK_MOUNT_OK" \
    sh -c 'mkdir -p "$PROC_ROOT" && . "$1/webman/scripts/common.sh" && mount_app "/volume2" "docker-ce"' _ "$REPO_ROOT"
)
jq -e '.success == true and .configUpdated == true' >/dev/null <<<"$F3_MNT_OUT" || \
    fail "F3 mount_app did not update config: $F3_MNT_OUT"
jq -e '.targetVolume == "/volume2" and ([.selectedApps[].name] == ["docker-ce"])' "$F3_ETC/mountfix.conf" >/dev/null || \
    fail "F3 mountfix.conf missing docker-ce after mount_app: $(cat "$F3_ETC/mountfix.conf")"
grep -qxF "$F3_VOL_ROOT/volume2/AppCentral/docker-ce:$F3_VOL1/.@plugins/AppCentral/docker-ce" "$F3_ETC/mounts.list" || \
    fail "F3 mounts.list missing docker-ce after mount_app: $(cat "$F3_ETC/mounts.list")"

# validate.cgi: docker-ce is configured but not actually bind-mounted -> configured_not_mounted
F3_VAL_CFG_ONLY=$(assert_cgi_json "$(
    DIR_VOL1="$F3_VOL1" \
    VOLUME_ROOT="$F3_VOL_ROOT" \
    CONFIG_FILE="$F3_ETC/mountfix.conf" \
    MF_CONFIG_DIR="$F3_ETC" \
    QUERY_STRING="$VALID_SID&act=get&target=/volume2" \
    ADM_AUTH_CGI="$MOCK_ADM_AUTH" \
    MOUNTFIX_WEBMAN_COMMON_SH="$REPO_ROOT/webman/scripts/common.sh" \
    MOUNTFIX_LIB_SH="$REPO_ROOT/CONTROL/lib.sh" \
    sh "$REPO_ROOT/webman/validate.cgi"
)" "F3 validate.cgi configured_not_mounted")
jq -e '
    .success == true and
    ((.apps[] | select(.name == "docker-ce") | .configured) == true) and
    ((.apps[] | select(.name == "docker-ce") | .mismatch) == "configured_not_mounted") and
    ((.apps[] | select(.name == "entware") | .configured) == false) and
    ((.apps[] | select(.name == "entware") | .mismatch) == null)
' >/dev/null <<<"$F3_VAL_CFG_ONLY" || fail "F3 validate.cgi configured_not_mounted mismatch: $F3_VAL_CFG_ONLY"

# unmount_app removes docker-ce from mountfix.conf and mounts.list
F3_UMNT_OUT=$(
    DIR_VOL1="$F3_VOL1" \
    VOLUME_ROOT="$F3_VOL_ROOT" \
    CONFIG_FILE="$F3_ETC/mountfix.conf" \
    MF_CONFIG_DIR="$F3_ETC" \
    PROC_ROOT="$TMP_DIR/empty_proc_f3" \
    UMOUNT_BIN="$MOCK_UMOUNT_OK" \
    sh -c '. "$1/webman/scripts/common.sh" && unmount_app "/volume2" "docker-ce"' _ "$REPO_ROOT"
)
jq -e '.success == true and .configUpdated == true' >/dev/null <<<"$F3_UMNT_OUT" || \
    fail "F3 unmount_app did not update config: $F3_UMNT_OUT"
jq -e '(.selectedApps | length) == 0' "$F3_ETC/mountfix.conf" >/dev/null || \
    fail "F3 mountfix.conf still contains docker-ce after unmount_app: $(cat "$F3_ETC/mountfix.conf")"
[ ! -s "$F3_ETC/mounts.list" ] || fail "F3 mounts.list not emptied after unmount_app: $(cat "$F3_ETC/mounts.list")"

# validate.cgi: simulated mounted_not_configured (entware reports mounted while not in config)
F3_MOUNTED_COMMON="$F3_ENV/mounted_common.sh"
cat <<EOF > "$F3_MOUNTED_COMMON"
. "$REPO_ROOT/webman/scripts/common.sh"
is_app_bind_mounted() { [ "\$2" = "entware" ]; }
EOF
F3_VAL_MNT_ONLY=$(assert_cgi_json "$(
    DIR_VOL1="$F3_VOL1" \
    VOLUME_ROOT="$F3_VOL_ROOT" \
    CONFIG_FILE="$F3_ETC/mountfix.conf" \
    MF_CONFIG_DIR="$F3_ETC" \
    QUERY_STRING="$VALID_SID&act=get&target=/volume2" \
    ADM_AUTH_CGI="$MOCK_ADM_AUTH" \
    MOUNTFIX_WEBMAN_COMMON_SH="$F3_MOUNTED_COMMON" \
    MOUNTFIX_LIB_SH="$REPO_ROOT/CONTROL/lib.sh" \
    sh "$REPO_ROOT/webman/validate.cgi"
)" "F3 validate.cgi mounted_not_configured")
jq -e '
    ((.apps[] | select(.name == "entware") | .configured) == false) and
    ((.apps[] | select(.name == "entware") | .mismatch) == "mounted_not_configured") and
    ((.apps[] | select(.name == "docker-ce") | .mismatch) == null)
' >/dev/null <<<"$F3_VAL_MNT_ONLY" || fail "F3 validate.cgi mounted_not_configured mismatch: $F3_VAL_MNT_ONLY"

echo "PASS: All shared library, F14 protection, url_decode, JSON helper, CGI hardening, F13 NVMe/df, and F3 mount-config sync tests passed."
