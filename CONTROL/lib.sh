#!/bin/sh

MF_ROOT="${MF_ROOT:-/usr/local/AppCentral/MountFix}"
DIR_VOL1="${DIR_VOL1:-/volume1}"
DIR_PLUGINS="${DIR_PLUGINS:-.@plugins}"
DIR_APP_CENTRAL="${DIR_APP_CENTRAL:-AppCentral}"
CONFIG_FILE="${CONFIG_FILE:-$MF_ROOT/etc/mountfix.conf}"
MOUNTS_LIST_FILE="${MOUNTS_LIST_FILE:-$(dirname "$CONFIG_FILE")/mounts.list}"
PROC_ROOT="${PROC_ROOT:-/proc}"
PROC_MOUNTS="${PROC_MOUNTS:-/proc/mounts}"

get_app_plugin_path() {
    printf '%s/%s/%s/%s\n' "$DIR_VOL1" "$DIR_PLUGINS" "$DIR_APP_CENTRAL" "$1"
}

get_app_data_path() {
    printf '%s%s/%s/%s\n' "${VOLUME_ROOT:-}" "$1" "$DIR_APP_CENTRAL" "$2"
}

is_protected_app() {
    [ "${1:-}" = "MountFix" ]
}

validate_app_name() {
    local app_name="${1:-}"
    [ -n "$app_name" ] || return 1
    is_protected_app "$app_name" && return 1
    case "$app_name" in
        *..*|*'
'*)
            return 1
            ;;
    esac
    printf '%s\n' "$app_name" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._+-]*$'
}

validate_target_volume() {
    local target_vol="${1:-}"
    case "$target_vol" in
        ""|*'
'*)
            return 1
            ;;
    esac
    printf '%s\n' "$target_vol" | grep -qE '^/volume[0-9]+$'
}

validate_mount_pair() {
    local src="${1:-}"
    local tgt="${2:-}"
    local src_app tgt_app

    [ -n "$src" ] && [ -n "$tgt" ] || return 1

    case "$src" in
        *:*|*/../*|*/..|../*|..|*'
'*)
            return 1
            ;;
    esac
    case "$tgt" in
        *:*|*/../*|*/..|../*|..|*'
'*)
            return 1
            ;;
    esac

    src_app="${src##*/}"
    tgt_app="${tgt##*/}"
    [ "$src_app" = "$tgt_app" ] || return 1
    validate_app_name "$src_app" || return 1

    case "$src" in
        /?*/"$DIR_APP_CENTRAL"/"$src_app") ;;
        *) return 1 ;;
    esac
    case "$tgt" in
        /?*/"$DIR_PLUGINS"/"$DIR_APP_CENTRAL"/"$tgt_app") ;;
        *) return 1 ;;
    esac

    return 0
}

json_escape() {
    printf '%s' "${1:-}" | awk '
    BEGIN { ORS = "" }
    {
        if (NR > 1) printf "\\n"
        n = length($0)
        for (i = 1; i <= n; i++) {
            c = substr($0, i, 1)
            if (c == "\\") printf "\\\\"
            else if (c == "\"") printf "\\\""
            else if (c == "\t") printf "\\t"
            else if (c == "\r") printf "\\r"
            else printf "%s", c
        }
    }'
}

is_mounted() {
    local src="$1"
    local tgt="$2"
    if [ -n "$src" ]; then
        [ -d "$src" ] && [ -d "$tgt" ] || return 1
        local s_ino t_ino
        s_ino=$(stat -c %d:%i "$src" 2>/dev/null) || return 1
        t_ino=$(stat -c %d:%i "$tgt" 2>/dev/null) || return 1
        [ "$s_ino" = "$t_ino" ]
        return $?
    fi
    awk -v tgt="$tgt" '$2 == tgt { found = 1; exit 0 } END { exit(found ? 0 : 1) }' "$PROC_MOUNTS" 2>/dev/null
}

is_app_bind_mounted() {
    local target_volume="$1"
    local app_name="$2"
    local bind_source bind_target

    bind_source=$(get_app_data_path "$target_volume" "$app_name")
    bind_target=$(get_app_plugin_path "$app_name")
    is_mounted "$bind_source" "$bind_target"
}

# Print PIDs of processes using anything under any of the given path prefixes
# (cwd, root, exe, open fds, mmapped files). Never signals or kills processes.
pids_using_paths() {
    local p pid hit l t prefix
    for p in "$PROC_ROOT"/[0-9]*; do
        [ -d "$p" ] || continue
        pid=${p##*/}
        [ "$pid" = "$$" ] && continue
        hit=0
        for l in "$p/cwd" "$p/root" "$p/exe" "$p"/fd/*; do
            t=$(readlink "$l" 2>/dev/null) || continue
            for prefix in "$@"; do
                [ -z "$prefix" ] && continue
                case "$t" in
                    "$prefix"|"$prefix"/*) hit=1; break 2 ;;
                esac
            done
        done
        if [ "$hit" -eq 0 ] && [ -r "$p/maps" ]; then
            for prefix in "$@"; do
                [ -z "$prefix" ] && continue
                if awk -v pfx="$prefix" '
                    NF >= 6 {
                        path = $6
                        if (path == pfx || substr(path, 1, length(pfx) + 1) == pfx "/") {
                            found = 1; exit 0
                        }
                    }
                    END { exit(found ? 0 : 1) }
                ' "$p/maps" 2>/dev/null; then
                    hit=1
                    break
                fi
            done
        fi
        [ "$hit" -eq 1 ] && echo "$pid"
    done
}

# Resolve jq binary even when Entware is not on PATH (e.g., ADM upgrade/init)
find_jq() {
    if command -v jq >/dev/null 2>&1; then
        command -v jq
        return 0
    fi
    for candidate in /usr/local/AppCentral/entware/opt/bin/jq /opt/bin/jq; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# Generate a plain-text mounts.list (SRC:TGT per line) from mountfix.conf so
# boot/shutdown never depends on jq or Entware.
generate_mounts_list() {
    local cfg="${1:-$CONFIG_FILE}"
    local list_file
    local jq_bin target_type target_vol tmp_file

    if [ -n "${2:-}" ]; then
        list_file="$2"
    elif [ -n "${1:-}" ]; then
        list_file="$(dirname "$1")/mounts.list"
    elif [ "$cfg" != "$MF_ROOT/etc/mountfix.conf" ] && [ "${MOUNTS_LIST_FILE:-}" = "$MF_ROOT/etc/mounts.list" ]; then
        list_file="$(dirname "$cfg")/mounts.list"
    else
        list_file="${MOUNTS_LIST_FILE:-$(dirname "$cfg")/mounts.list}"
    fi

    if [ ! -f "$cfg" ]; then
        echo "Error: Configuration file not found at $cfg" >&2
        return 1
    fi

    jq_bin=$(find_jq) || {
        echo "Error: jq not found; cannot generate $list_file" >&2
        return 1
    }

    target_type=$("$jq_bin" -r '.targetVolume | type' "$cfg" 2>/dev/null) || {
        echo "Error: Failed to parse $cfg" >&2
        return 1
    }
    if [ "$target_type" != "string" ]; then
        echo "Error: targetVolume is undefined or invalid in $cfg" >&2
        return 1
    fi

    target_vol=$("$jq_bin" -r '.targetVolume' "$cfg" 2>/dev/null)
    tmp_file="${list_file}.tmp.$$"

    if [ -z "$target_vol" ]; then
        : > "$tmp_file" && mv "$tmp_file" "$list_file"
        return $?
    fi

    if ! validate_target_volume "$target_vol"; then
        echo "Error: Invalid targetVolume '$target_vol'" >&2
        return 1
    fi

    "$jq_bin" -r \
        '.selectedApps[]? | select(.enabled == true or .enabled == null) | .name // empty' "$cfg" 2>/dev/null | \
    while IFS= read -r app_name; do
        validate_app_name "$app_name" || continue
        printf '%s:%s\n' "$(get_app_data_path "$target_vol" "$app_name")" "$(get_app_plugin_path "$app_name")"
    done > "$tmp_file"

    mv "$tmp_file" "$list_file"
}

# Retrieve enabled mount points as "SRC:TGT" lines.
# Primary path reads pre-generated mounts.list with pure sh (no jq required).
# Falls back to parsing mountfix.conf with jq if mounts.list does not exist yet.
get_mount_configs() {
    local cfg="${CONFIG_FILE:-$MF_ROOT/etc/mountfix.conf}"
    local list_file
    local jq_bin target_vol line src tgt

    if [ "$cfg" != "$MF_ROOT/etc/mountfix.conf" ] && [ "${MOUNTS_LIST_FILE:-}" = "$MF_ROOT/etc/mounts.list" ]; then
        list_file="$(dirname "$cfg")/mounts.list"
    else
        list_file="${MOUNTS_LIST_FILE:-$(dirname "$cfg")/mounts.list}"
    fi

    if [ -f "$list_file" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                ""|\#*) continue ;;
                *:*:*) continue ;;
                *:*) ;;
                *) continue ;;
            esac
            src="${line%%:*}"
            tgt="${line#*:}"
            validate_mount_pair "$src" "$tgt" || continue
            printf '%s:%s\n' "$src" "$tgt"
        done < "$list_file"
        return 0
    fi

    if [ ! -f "$cfg" ]; then
        echo "Error: Configuration file not found at $cfg (and no $list_file)" >&2
        return 1
    fi

    jq_bin=$(find_jq) || {
        echo "Error: $list_file missing and jq not found; cannot parse $cfg" >&2
        return 1
    }

    target_vol=$("$jq_bin" -r '.targetVolume // empty' "$cfg" 2>/dev/null)
    if ! validate_target_volume "$target_vol"; then
        echo "Error: targetVolume is undefined or invalid in config" >&2
        return 1
    fi

    "$jq_bin" -r \
        '.selectedApps[]? | select(.enabled == true or .enabled == null) | .name // empty' "$cfg" 2>/dev/null | \
    while IFS= read -r app_name; do
        validate_app_name "$app_name" || continue
        printf '%s:%s\n' "$(get_app_data_path "$target_vol" "$app_name")" "$(get_app_plugin_path "$app_name")"
    done
}

# Check whether optional sysctl tuning is enabled in mountfix.conf (jq-free for boot)
is_sysctl_tuning_enabled() {
    local cfg="${1:-$CONFIG_FILE}"
    [ -f "$cfg" ] || return 1
    grep -qE '"enableSysctlTuning"[[:space:]]*:[[:space:]]*true' "$cfg" 2>/dev/null
}
