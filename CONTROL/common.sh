#!/bin/sh

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
    local cfg="${1:-${CONFIG_FILE:-/usr/local/AppCentral/MountFix/etc/mountfix.conf}}"
    local list_file="${2:-${MOUNTS_LIST_FILE:-$(dirname "$cfg")/mounts.list}}"
    local jq_bin target_vol tmp_file

    if [ ! -f "$cfg" ]; then
        echo "Error: Configuration file not found at $cfg" >&2
        return 1
    fi

    jq_bin=$(find_jq) || {
        echo "Error: jq not found; cannot generate $list_file" >&2
        return 1
    }

    target_vol=$("$jq_bin" -r '.targetVolume // empty' "$cfg" 2>/dev/null)
    case "$target_vol" in
        /volume[0-9]*)
            # Reject path traversal or trailing segments
            echo "$target_vol" | grep -qE '^/volume[0-9]+$' || {
                echo "Error: Invalid targetVolume '$target_vol'" >&2
                return 1
            }
            ;;
        *)
            echo "Error: targetVolume is undefined or invalid in $cfg" >&2
            return 1
            ;;
    esac

    tmp_file="${list_file}.tmp.$$"
    "$jq_bin" -r --arg vol "$target_vol" \
        '.selectedApps[]? | select(.enabled == true or .enabled == null) | .name // empty' "$cfg" 2>/dev/null | \
    while IFS= read -r app_name; do
        [ -z "$app_name" ] && continue
        [ "$app_name" = "MountFix" ] && continue
        echo "$app_name" | grep -qE '^[A-Za-z0-9._-]+$' || continue
        case "$app_name" in
            .*|*..*) continue ;;
        esac
        printf '%s/AppCentral/%s:/volume1/.@plugins/AppCentral/%s\n' "$target_vol" "$app_name" "$app_name"
    done > "$tmp_file"

    mv "$tmp_file" "$list_file"
}

# Retrieve enabled mount points as "SRC:TGT" lines.
# Primary path reads pre-generated mounts.list with pure sh (no jq required).
# Falls back to parsing mountfix.conf with jq if mounts.list does not exist yet.
get_mount_configs() {
    local cfg="${CONFIG_FILE:-/usr/local/AppCentral/MountFix/etc/mountfix.conf}"
    local list_file="${MOUNTS_LIST_FILE:-$(dirname "$cfg")/mounts.list}"
    local jq_bin target_vol

    if [ -f "$list_file" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                ""|\#*) continue ;;
            esac
            echo "$line" | grep -qE '^/[^:]+:/[^:]+$' || continue
            printf '%s\n' "$line"
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
    if [ -z "$target_vol" ] || [ "$target_vol" = "null" ]; then
        echo "Error: targetVolume is undefined in config" >&2
        return 1
    fi

    "$jq_bin" -r --arg vol "$target_vol" \
        '.selectedApps[]? | select(.enabled == true or .enabled == null) | "\($vol)/AppCentral/\(.name):/volume1/.@plugins/AppCentral/\(.name)"' "$cfg"
}
