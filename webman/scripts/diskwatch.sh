#!/bin/sh
# MountFix HDD Activity Monitor (read-only background observer)
# Tracks physical HDD /proc/diskstats deltas and attributes I/O to processes & AppCentral apps.
# All runtime state lives strictly in tmpfs (/tmp) so monitoring never wakes sleeping HDDs.

DISKWATCH_TMP_DIR="${TMPDIR:-/tmp}"
DISKWATCH_LOCK_DIR="${DISKWATCH_LOCK_DIR:-$DISKWATCH_TMP_DIR/mountfix_diskwatch.lock}"
DISKWATCH_STATUS_FILE="${DISKWATCH_STATUS_FILE:-$DISKWATCH_TMP_DIR/mountfix_diskwatch.status.json}"
DISKWATCH_STATE_DIR="${DISKWATCH_STATE_DIR:-$DISKWATCH_TMP_DIR/mountfix_diskwatch.state}"
DISKWATCH_MAX_TIMELINE="${DISKWATCH_MAX_TIMELINE:-200}"
DISKWATCH_HDPARM_BIN="${DISKWATCH_HDPARM_BIN:-hdparm}"

####################################################################
# Validate duration against strict whitelist (30s..12h)
####################################################################
diskwatch_validate_duration() {
    case "${1:-}" in
        30|60|300|600|1200|1800|2700|3600|7200|10800|14400|21600|28800|43200)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

####################################################################
# Validate collector mode against strict whitelist
####################################################################
diskwatch_validate_collector() {
    case "${1:-auto}" in
        auto|iotop-static|proc-io)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

####################################################################
# Adaptive sampling interval (seconds) for a validated duration
####################################################################
diskwatch_interval_for_duration() {
    case "${1:-}" in
        30|60)
            echo "1"
            ;;
        300|600|1200)
            echo "3"
            ;;
        1800|2700|3600)
            echo "5"
            ;;
        7200|10800|14400|21600|28800|43200)
            echo "10"
            ;;
        *)
            echo "3"
            ;;
    esac
}

####################################################################
# Portable stat st_dev helper (Linux/BusyBox and macOS tests)
####################################################################
_diskwatch_stat_dev() {
    local target="$1"
    stat -L -c %d "$target" 2>/dev/null || stat -L -f %d "$target" 2>/dev/null || return 1
}

####################################################################
# Discover rotational base disks (rotational == 1), watched diskstats
# devices (base + partitions + rotational md*), and HDD volume st_devs.
# Writes:
#   $1/base_disks.txt   (one base disk per line, e.g. sda)
#   $1/watch_devs.txt   (one diskstats dev per line, e.g. sda, sda4, md1)
#   $1/hdd_vols.tsv     (vol_path<TAB>st_dev)
####################################################################
discover_hdd_devices() {
    local out_dir="$1"
    local sys_block="${SYS_BLOCK_DIR:-/sys/block}"
    local diskstats="${DISKWATCH_DISKSTATS:-${PROC_ROOT:-/proc}/diskstats}"
    local volumes_root="${VOLUMES_ROOT:-}"
    local base_file="$out_dir/base_disks.txt"
    local watch_file="$out_dir/watch_devs.txt"
    local vols_file="$out_dir/hdd_vols.tsv"
    local dev_path dev_name rot_val slave slave_base is_rot vol_dir vol_path st_dev

    volumes_root="${volumes_root%/}"
    : > "$base_file"
    : > "$watch_file"
    : > "$vols_file"

    # 1. Find physical rotational base disks (exclude virtual/md/dm/optical)
    for dev_path in "$sys_block"/*; do
        [ -d "$dev_path" ] || continue
        dev_name="${dev_path##*/}"
        case "$dev_name" in
            loop*|ram*|zram*|sr*|fd*|md*|dm-*) continue ;;
        esac
        if [ -r "$dev_path/queue/rotational" ]; then
            rot_val=$(tr -d ' \t\r\n' < "$dev_path/queue/rotational" 2>/dev/null || true)
            if [ "$rot_val" = "1" ]; then
                printf '%s\n' "$dev_name" >> "$base_file"
                printf '%s\n' "$dev_name" >> "$watch_file"
            fi
        fi
    done

    # 2. Add rotational md* arrays whose slaves belong to rotational base disks
    for dev_path in "$sys_block"/md*; do
        [ -d "$dev_path" ] || continue
        dev_name="${dev_path##*/}"
        is_rot=0
        if [ -d "$dev_path/slaves" ]; then
            for slave in "$dev_path"/slaves/*; do
                [ -e "$slave" ] || continue
                slave_base=$(resolve_base_block_device "${slave##*/}")
                if [ -n "$slave_base" ] && grep -qx "$slave_base" "$base_file" 2>/dev/null; then
                    is_rot=1
                    break
                fi
            done
        fi
        if [ "$is_rot" -eq 1 ]; then
            printf '%s\n' "$dev_name" >> "$watch_file"
        fi
    done

    # 3. Add partitions of rotational base disks found in /proc/diskstats
    if [ -r "$diskstats" ] && [ -s "$base_file" ]; then
        awk '
            NR == FNR { base[$1] = 1; next }
            NF >= 10 {
                dev = $3
                for (b in base) {
                    if (index(dev, b) == 1 && length(dev) > length(b)) {
                        rest = substr(dev, length(b) + 1)
                        if (rest ~ /^[0-9]+$/ || rest ~ /^p[0-9]+$/) {
                            print dev
                            break
                        }
                    }
                }
            }
        ' "$base_file" "$diskstats" 2>/dev/null >> "$watch_file"
    fi

    # Deduplicate watch_devs.txt
    if [ -s "$watch_file" ]; then
        awk '!seen[$0]++' "$watch_file" > "$watch_file.tmp" && mv "$watch_file.tmp" "$watch_file"
    fi

    # 4. Find ALL mounted filesystems backed by watched HDD devices (e.g. / on md0, /volume1 on md1)
    if [ -r "$PROC_MOUNTS" ] && [ -s "$watch_file" ]; then
        awk '
            NR == FNR { w[$1] = 1; next }
            $1 ~ /^\/dev\// {
                dev = $1
                sub(/^\/dev\//, "", dev)
                if (dev in w) print $2
            }
        ' "$watch_file" "$PROC_MOUNTS" 2>/dev/null | while IFS= read -r mnt_path; do
            [ -d "$mnt_path" ] || continue
            st_dev=$(_diskwatch_stat_dev "$mnt_path" || true)
            [ -n "$st_dev" ] && printf '%s\t%s\n' "$mnt_path" "$st_dev" >> "$vols_file"
        done
    fi

    # Also include /volume[0-9]* where get_volume_rotational reports HDD (handles test roots / symlinks)
    for vol_dir in "${volumes_root}"/volume[0-9]*; do
        [ -d "$vol_dir" ] || continue
        vol_path="${vol_dir#"${volumes_root}"}"
        if [ "$(get_volume_rotational "$vol_dir")" = "1" ]; then
            st_dev=$(_diskwatch_stat_dev "$vol_dir" || true)
            [ -n "$st_dev" ] && printf '%s\t%s\n' "$vol_path" "$st_dev" >> "$vols_file"
        fi
    done

    if [ -s "$vols_file" ]; then
        awk '!seen[$0]++' "$vols_file" > "$vols_file.tmp" && mv "$vols_file.tmp" "$vols_file"
    fi
}

####################################################################
# Query HDD power states via hdparm -C (never wakes standby drives)
####################################################################
get_hdd_power_states_json() {
    local base_file="$1"
    local hdparm_bin="${DISKWATCH_HDPARM_BIN:-hdparm}"
    local has_hdparm=0
    local out="[" first=1 disk state raw disk_esc state_esc

    if [ -x "$hdparm_bin" ] || command -v "$hdparm_bin" >/dev/null 2>&1; then
        has_hdparm=1
    fi

    if [ -r "$base_file" ]; then
        while IFS= read -r disk; do
            [ -n "$disk" ] || continue
            state="unknown"
            if [ "$has_hdparm" -eq 1 ]; then
                raw=$("$hdparm_bin" -C "/dev/$disk" </dev/null 2>/dev/null || true)
                state=$(printf '%s\n' "$raw" | awk -F':' '/drive state is/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }')
                [ -n "$state" ] || state="unknown"
            fi
            disk_esc=$(json_escape "$disk")
            state_esc=$(json_escape "$state")
            [ "$first" -eq 0 ] && out="$out,"
            first=0
            out="$out{\"disk\":\"$disk_esc\",\"state\":\"$state_esc\"}"
        done < "$base_file"
    fi

    printf '%s]\n' "$out"
}

####################################################################
# Detect best available I/O collector:
#   Prints "iotop-static:<path>" if probe succeeds, else "proc-io:"
####################################################################
detect_io_collector() {
    local mf_root="${MF_ROOT:-/usr/local/AppCentral/MountFix}"
    local cand=""

    if [ -n "${DISKWATCH_IOTOP_BIN+x}" ]; then
        if [ -n "$DISKWATCH_IOTOP_BIN" ] && [ -x "$DISKWATCH_IOTOP_BIN" ]; then
            if "$DISKWATCH_IOTOP_BIN" -b -o -P -k -d 1 -n 1 -q </dev/null >/dev/null 2>&1; then
                printf 'iotop-static:%s\n' "$DISKWATCH_IOTOP_BIN"
                return 0
            fi
        fi
        printf 'proc-io:\n'
        return 0
    fi

    for cand in \
        "$mf_root/bin/iotop-static" \
        "/opt/sbin/iotop-static" \
        "/usr/local/AppCentral/entware/opt/sbin/iotop-static"; do
        if [ -x "$cand" ]; then
            if "$cand" -b -o -P -k -d 1 -n 1 -q </dev/null >/dev/null 2>&1; then
                printf 'iotop-static:%s\n' "$cand"
                return 0
            fi
        fi
    done

    printf 'proc-io:\n'
    return 0
}

####################################################################
# Snapshot watched devices from /proc/diskstats
# Output: dev<TAB>sectors_read<TAB>sectors_written
####################################################################
_diskwatch_snap_diskstats() {
    local watch_file="$1"
    local diskstats="${DISKWATCH_DISKSTATS:-${PROC_ROOT:-/proc}/diskstats}"
    [ -r "$diskstats" ] && [ -s "$watch_file" ] || return 0
    awk '
        NR == FNR { w[$1] = 1; next }
        ($3 in w) && NF >= 10 { print $3 "\t" $6 "\t" $10 }
    ' "$watch_file" "$diskstats" 2>/dev/null
}

####################################################################
# Snapshot /proc/<pid>/io + /proc/<pid>/stat for fallback collector
# Output: pid<TAB>comm<TAB>read_bytes<TAB>write_bytes<TAB>state
####################################################################
_diskwatch_snap_proc_io() {
    local proc_root="${PROC_ROOT:-/proc}"
    local p pid stat_line comm state io_line rb wb cwb
    for p in "$proc_root"/[0-9]*; do
        [ -d "$p" ] || continue
        pid="${p##*/}"
        [ -r "$p/stat" ] || continue
        stat_line=$(cat "$p/stat" 2>/dev/null) || continue
        comm=$(printf '%s\n' "$stat_line" | awk 'BEGIN{FS=") "} { c=$1; sub(/^[^(]*\(/,"",c); gsub(/[\t\r\n]/, " ", c); print c }')
        [ -n "$comm" ] || comm="pid-$pid"
        state=$(printf '%s\n' "$stat_line" | awk 'BEGIN{FS=") "} { split($2, b, " "); print b[1] }')
        rb=0; wb=0; cwb=0
        if [ -r "$p/io" ]; then
            io_line=$(awk '
                $1 == "read_bytes:" { r = $2 }
                $1 == "write_bytes:" { w = $2 }
                $1 == "cancelled_write_bytes:" { c = $2 }
                END { printf "%s %s %s\n", r+0, w+0, c+0 }
            ' "$p/io" 2>/dev/null || echo "0 0 0")
            rb=$(printf '%s\n' "$io_line" | awk '{print $1}')
            wb=$(printf '%s\n' "$io_line" | awk '{print $2}')
            cwb=$(printf '%s\n' "$io_line" | awk '{print $3}')
            if [ "$wb" -gt "$cwb" ]; then
                wb=$((wb - cwb))
            else
                wb=0
            fi
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$comm" "$rb" "$wb" "$state"
    done
}

####################################################################
# Parse iotop-static 1.31 batch output into normalized TSV:
#   pid<TAB>comm<TAB>read_kb<TAB>write_kb<TAB>d_state
####################################################################
parse_iotop_batch_output() {
    local interval="${1:-1}"
    local proc_root="${PROC_ROOT:-/proc}"
    awk -v iv="$interval" '
        function to_kb(val, unit,    m, kb) {
            if (val <= 0) return 0
            if (unit ~ /^B/) m = 1.0 / 1024.0
            else if (unit ~ /^K/) m = 1.0
            else if (unit ~ /^M/) m = 1024.0
            else if (unit ~ /^G/) m = 1048576.0
            else m = 1.0
            kb = int((val * m * iv) + 0.5)
            return (kb < 1 ? 1 : kb)
        }
        /^[[:space:]]*[0-9]+[[:space:]]/ {
            pid = $1
            # Format: PID PRIO USER R_VAL R_UNIT W_VAL W_UNIT SWAPIN [%] IO [%] COMMAND...
            rkb = to_kb($4 + 0, $5)
            wkb = to_kb($6 + 0, $7)
            if (rkb <= 0 && wkb <= 0) next
            # Extract COMMAND after the last "%" field (or from field 8 onward)
            cmd = ""
            pct_seen = 0
            cmd_start = 8
            for (i = 8; i <= NF; i++) {
                if ($i == "%") {
                    pct_seen++
                    cmd_start = i + 1
                    if (pct_seen >= 2) break
                } else if ($i == "?unavailable?") {
                    cmd_start = i + 1
                }
            }
            for (i = cmd_start; i <= NF; i++) {
                cmd = (cmd == "" ? $i : cmd " " $i)
            }
            # Trim to basename for userspace paths; preserve kernel thread names like [jbd2/md1-8]
            split(cmd, parts, " ")
            comm = parts[1]
            if (comm ~ /^\[.*\]$/) {
                gsub(/^\[|\]$/, "", comm)
            } else {
                sub(/^.*\//, "", comm)
            }
            gsub(/[\t\r\n]/, " ", comm)
            if (comm == "") comm = "pid-" pid
            printf "%s\t%s\t%d\t%d\t0\n", pid, comm, rkb, wkb
        }
    ' | while IFS="$(printf '\t')" read -r pid comm rkb wkb dstate; do
        # Enrich D-state from /proc/<pid>/stat if process still exists
        if [ -r "$proc_root/$pid/stat" ]; then
            if awk 'BEGIN{FS=") "} { split($2, b, " "); exit(b[1] == "D" ? 0 : 1) }' "$proc_root/$pid/stat" 2>/dev/null; then
                dstate=1
            fi
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$comm" "$rkb" "$wkb" "$dstate"
    done
}

####################################################################
# Attribute a PID to HDD vs SSD via st_dev and AppCentral paths.
# Output: hdd_hit<TAB>app_name<TAB>reloc_status
#   hdd_hit: 1 (confirmed HDD or HDD kernel thread), 0 (confirmed SSD-only), 2 (exited/unknown)
#   reloc_status: hdd_relocatable | ssd_mounted | system
####################################################################
_diskwatch_attribute_pid() {
    local pid="$1"
    local comm="$2"
    local vols_file="$3"
    local watch_file="$4"
    local proc_root="${PROC_ROOT:-/proc}"
    local p="$proc_root/$pid"
    local hdd_hit=2 app_name="" reloc_status="system"
    local link_path target_path st_dev any_fd=0 fd_checked=0
    local vol_prefix="${DIR_VOL1:-/volume1}/${DIR_PLUGINS:-.@plugins}/${DIR_APP_CENTRAL:-AppCentral}/"
    local cmdline="" hdd_st_devs=""
    local mounts_list="${MOUNTS_LIST_FILE:-$(dirname "${CONFIG_FILE:-/usr/local/AppCentral/MountFix/etc/mountfix.conf}")/mounts.list}"

    # Kernel threads tied to watched HDD/md devices (e.g. jbd2/md1-8, md1_raid5)
    case "$comm" in
        jbd2/*|md*_raid*|md*_resync|kswapd*|kworker*)
            if [ -s "$watch_file" ]; then
                while IFS= read -r wdev; do
                    case "$comm" in
                        *"$wdev"*)
                            printf '1\t\tsystem\n'
                            return 0
                            ;;
                    esac
                done < "$watch_file"
            fi
            ;;
    esac

    [ -d "$p" ] || {
        printf '2\t\tsystem\n'
        return 0
    }

    # Load HDD st_dev set once into a space-delimited string (zero awk forks per FD)
    if [ -s "$vols_file" ]; then
        hdd_st_devs=" $(awk -F'\t' '{printf "%s ", $2}' "$vols_file") "
    fi

    # Inspect cwd, exe, and up to 32 real open fds (break early once HDD hit + app_name known)
    for link_path in "$p/cwd" "$p/exe" "$p"/fd/*; do
        [ -L "$link_path" ] || [ -e "$link_path" ] || continue
        target_path=$(readlink "$link_path" 2>/dev/null) || continue
        case "$target_path" in
            /*) ;;
            *) continue ;;
        esac
        case "$target_path" in
            /proc/*|/sys/*|/dev/*|/tmp/*|/run/*) continue ;;
        esac
        any_fd=1
        fd_checked=$((fd_checked + 1))

        # Check AppCentral path
        if [ -z "$app_name" ]; then
            case "$target_path" in
                "$vol_prefix"*)
                    app_name="${target_path#"$vol_prefix"}"
                    app_name="${app_name%%/*}"
                    ;;
                /usr/local/AppCentral/*)
                    app_name="${target_path#/usr/local/AppCentral/}"
                    app_name="${app_name%%/*}"
                    ;;
            esac
        fi

        if [ "$hdd_hit" -ne 1 ] && [ -n "$hdd_st_devs" ]; then
            st_dev=$(_diskwatch_stat_dev "$link_path" || true)
            if [ -n "$st_dev" ]; then
                case "$hdd_st_devs" in
                    *" $st_dev "*) hdd_hit=1 ;;
                esac
            fi
        fi

        if [ "$hdd_hit" -eq 1 ] && [ -n "$app_name" ]; then
            break
        fi
        [ "$fd_checked" -ge 32 ] && break
    done

    # If we saw real file descriptors on other volumes (e.g. SSD) and none on HDD, mark SSD-only
    if [ "$hdd_hit" -eq 2 ] && [ "$any_fd" -eq 1 ]; then
        hdd_hit=0
    fi

    # Fallback AppCentral match via cmdline if still unmapped
    if [ -z "$app_name" ] && [ -r "$p/cmdline" ]; then
        cmdline=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null || true)
        case "$cmdline" in
            *"$vol_prefix"*)
                app_name="${cmdline#*"$vol_prefix"}"
                app_name="${app_name%%/*}"
                app_name="${app_name%% *}"
                ;;
            *"/usr/local/AppCentral/"*)
                app_name="${cmdline#*"/usr/local/AppCentral/"}"
                app_name="${app_name%%/*}"
                app_name="${app_name%% *}"
                ;;
        esac
    fi

    if [ -n "$app_name" ]; then
        if [ "$app_name" = "MountFix" ]; then
            reloc_status="system"
        elif [ -f "$mounts_list" ] && grep -q ":${vol_prefix}${app_name}$" "$mounts_list" 2>/dev/null; then
            # App itself is already relocated on SSD (it was just reading/writing user data on HDD)
            reloc_status="ssd_mounted"
        elif [ "$hdd_hit" -eq 1 ]; then
            reloc_status="hdd_relocatable"
        elif [ "$hdd_hit" -eq 0 ]; then
            reloc_status="ssd_mounted"
        fi
    fi

    printf '%s\t%s\t%s\n' "$hdd_hit" "$app_name" "$reloc_status"
}

####################################################################
# Atomically write status JSON from accumulated state files
####################################################################
_diskwatch_write_status_json() {
    local state="$1"
    local collector="$2"
    local duration="$3"
    local interval="$4"
    local elapsed="$5"
    local started_at="$6"
    local base_file="$7"
    local power_json="$8"
    local total_rkb="$9"
    local total_wkb="${10}"
    local event_count="${11}"
    local culprits_file="${12}"
    local timeline_file="${13}"
    local err_msg="${14:-}"

    local status_file="$DISKWATCH_STATUS_FILE"
    local tmp_file="${status_file}.tmp.$$"
    local updated_at devs_json culprits_json timeline_json first disk d_esc
    local err_esc collector_esc state_esc started_esc updated_esc

    updated_at=$(date '+%Y-%m-%d %H:%M:%S')

    # Base HDD devices JSON array
    devs_json="["
    first=1
    if [ -r "$base_file" ]; then
        while IFS= read -r disk; do
            [ -n "$disk" ] || continue
            d_esc=$(json_escape "$disk")
            [ "$first" -eq 0 ] && devs_json="$devs_json,"
            first=0
            devs_json="$devs_json\"$d_esc\""
        done < "$base_file"
    fi
    devs_json="$devs_json]"

    # Culprits JSON array (built in awk -F'\t' so empty appName fields \t\t NEVER shift columns!)
    culprits_json="[]"
    if [ -s "$culprits_file" ]; then
        sort -t "$(printf '\t')" -k4,4nr -k6,6nr -k5,5nr "$culprits_file" | head -n 50 > "$tmp_file.culp"
        culprits_json=$(awk -F'\t' '
            function esc(s,    out, i, n, c) {
                out = ""
                n = length(s)
                for (i = 1; i <= n; i++) {
                    c = substr(s, i, 1)
                    if (c == "\\") out = out "\\\\"
                    else if (c == "\"") out = out "\\\""
                    else if (c == "\t") out = out "\\t"
                    else if (c == "\r") out = out "\\r"
                    else out = out c
                }
                return out
            }
            BEGIN { printf "["; first = 1 }
            NF >= 1 && $1 != "" {
                if (!first) printf ","
                first = 0
                rs = ($9 != "" ? $9 : "system")
                printf "{\"key\":\"%s\",\"process\":\"%s\",\"appName\":\"%s\",\"hits\":%d,\"readKB\":%d,\"writeKB\":%d,\"dState\":%d,\"lastSeen\":\"%s\",\"relocationStatus\":\"%s\"}",
                    esc($1), esc($2), esc($3), ($4 + 0), ($5 + 0), ($6 + 0), ($7 + 0), esc($8), esc(rs)
            }
            END { printf "]" }
        ' "$tmp_file.culp")
        rm -f "$tmp_file.culp"
    fi

    # Timeline JSON array (built in awk -F'\t' so empty columns never shift fields)
    timeline_json="[]"
    if [ -s "$timeline_file" ]; then
        timeline_json=$(awk -F'\t' '
            function esc(s,    out, i, n, c) {
                out = ""
                n = length(s)
                for (i = 1; i <= n; i++) {
                    c = substr(s, i, 1)
                    if (c == "\\") out = out "\\\\"
                    else if (c == "\"") out = out "\\\""
                    else if (c == "\t") out = out "\\t"
                    else if (c == "\r") out = out "\\r"
                    else out = out c
                }
                return out
            }
            BEGIN { printf "["; first = 1 }
            NF >= 1 && $1 != "" {
                if (!first) printf ","
                first = 0
                printf "{\"time\":\"%s\",\"devices\":\"%s\",\"processes\":\"%s\"}",
                    esc($1), esc($2), esc($3)
            }
            END { printf "]" }
        ' "$timeline_file")
    fi

    state_esc=$(json_escape "$state")
    collector_esc=$(json_escape "$collector")
    started_esc=$(json_escape "$started_at")
    updated_esc=$(json_escape "$updated_at")
    err_esc=$(json_escape "$err_msg")

    printf '{"state":"%s","collector":"%s","duration":%d,"interval":%d,"elapsed":%d,"startedAt":"%s","updatedAt":"%s","hddDevices":%s,"hddPower":%s,"hddReadKB":%d,"hddWriteKB":%d,"eventCount":%d,"error":"%s","culprits":%s,"timeline":%s}\n' \
        "$state_esc" "$collector_esc" "$duration" "$interval" "$elapsed" \
        "$started_esc" "$updated_esc" "$devs_json" "$power_json" \
        "$total_rkb" "$total_wkb" "$event_count" "$err_esc" \
        "$culprits_json" "$timeline_json" > "$tmp_file" && mv "$tmp_file" "$status_file"
}

####################################################################
# Acquire / release atomic diskwatch lock
####################################################################
acquire_diskwatch_lock() {
    local lock_dir="$DISKWATCH_LOCK_DIR"
    local owner="$1"
    local existing_pid=""

    if mkdir "$lock_dir" 2>/dev/null; then
        printf '%s\n' "$$" > "$lock_dir/pid"
        printf '%s\n' "$owner" > "$lock_dir/owner"
        return 0
    fi

    if [ -f "$lock_dir/pid" ]; then
        existing_pid=$(cat "$lock_dir/pid" 2>/dev/null || true)
    fi

    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
        return 1
    fi

    rm -rf "$lock_dir" 2>/dev/null || true
    if mkdir "$lock_dir" 2>/dev/null; then
        printf '%s\n' "$$" > "$lock_dir/pid"
        printf '%s\n' "$owner" > "$lock_dir/owner"
        return 0
    fi
    return 1
}

release_diskwatch_lock() {
    local lock_dir="$DISKWATCH_LOCK_DIR"
    local owner="$1"
    local current_owner=""

    [ -d "$lock_dir" ] || return 0
    current_owner=$(cat "$lock_dir/owner" 2>/dev/null || true)
    if [ -z "$owner" ] || [ "$current_owner" = "$owner" ]; then
        rm -rf "$lock_dir" 2>/dev/null || true
    fi
}

####################################################################
# Merge one sample's attributed culprits into culprits.tsv
# culprits.tsv: key<TAB>proc<TAB>app<TAB>hits<TAB>rkb<TAB>wkb<TAB>dstate<TAB>last_seen<TAB>rstatus
####################################################################
_diskwatch_merge_culprit() {
    local culprits_file="$1"
    local key="$2"
    local proc="$3"
    local app="$4"
    local rkb="$5"
    local wkb="$6"
    local dstate="$7"
    local ts="$8"
    local rstatus="$9"
    local tmp="$culprits_file.tmp.$$"

    # Pass strings via ENVIRON (not awk -v) so backslashes are never interpreted as escapes
    DW_K="$key" DW_PR="$proc" DW_AP="$app" DW_R="$rkb" DW_W="$wkb" \
    DW_D="$dstate" DW_T="$ts" DW_RS="$rstatus" \
    awk -F'\t' -v OFS='\t' '
        BEGIN {
            k = ENVIRON["DW_K"]
            pr = ENVIRON["DW_PR"]
            ap = ENVIRON["DW_AP"]
            r = ENVIRON["DW_R"] + 0
            w = ENVIRON["DW_W"] + 0
            d = ENVIRON["DW_D"] + 0
            t = ENVIRON["DW_T"]
            rs = ENVIRON["DW_RS"]
            gsub(/[\t\r\n]/, " ", k)
            gsub(/[\t\r\n]/, " ", pr)
            gsub(/[\t\r\n]/, " ", ap)
            found = 0
        }
        $1 == k {
            $4 = ($4 + 0) + 1
            $5 = ($5 + 0) + r
            $6 = ($6 + 0) + w
            $7 = ($7 + 0) + d
            $8 = t
            if (rs == "hdd_relocatable" || $9 == "") $9 = rs
            found = 1
        }
        { print }
        END {
            if (!found) {
                print k, pr, ap, 1, r, w, d, t, rs
            }
        }
    ' "$culprits_file" > "$tmp" && mv "$tmp" "$culprits_file"
}

####################################################################
# Core sampling worker loop (runs detached in background)
####################################################################
_diskwatch_worker_loop() {
    local duration="$1"
    local interval="$2"
    local collector_name="$3"
    local iotop_bin="$4"
    local lock_owner="$5"

    local state_dir="$DISKWATCH_STATE_DIR"
    local base_file="$state_dir/base_disks.txt"
    local watch_file="$state_dir/watch_devs.txt"
    local vols_file="$state_dir/hdd_vols.tsv"
    local prev_ds="$state_dir/prev_diskstats"
    local cur_ds="$state_dir/cur_diskstats"
    local prev_io="$state_dir/prev_io"
    local cur_io="$state_dir/cur_io"
    local sample_io="$state_dir/sample_io"
    local culprits_file="$state_dir/culprits.tsv"
    local timeline_file="$state_dir/timeline.tsv"

    local start_ts now_ts end_ts elapsed started_at power_json
    local total_rkb=0 total_wkb=0 event_count=0
    local ds_delta_summary sample_base_rkb sample_base_wkb
    local stopped_by_signal=0
    local my_pid="$$"

    mkdir -p "$state_dir"
    rm -f "$state_dir/stop.req"
    : > "$culprits_file"
    : > "$timeline_file"

    discover_hdd_devices "$state_dir"
    power_json=$(get_hdd_power_states_json "$base_file")

    # Initialize baselines BEFORE the loop so the first sample never emits a false wakeup
    _diskwatch_snap_diskstats "$watch_file" > "$prev_ds"
    if [ "$collector_name" = "proc-io" ]; then
        _diskwatch_snap_proc_io > "$prev_io"
    fi

    start_ts=$(date +%s)
    end_ts=$((start_ts + duration))
    started_at=$(date '+%Y-%m-%d %H:%M:%S')
    local last_power_ts="$start_ts"

    # Write initial running status
    _diskwatch_write_status_json "running" "$collector_name" "$duration" "$interval" 0 \
        "$started_at" "$base_file" "$power_json" 0 0 0 "$culprits_file" "$timeline_file" ""

    trap 'stopped_by_signal=1' TERM INT

    while [ "$stopped_by_signal" -eq 0 ] && [ ! -f "$state_dir/stop.req" ]; do
        now_ts=$(date +%s)
        [ "$now_ts" -ge "$end_ts" ] && break

        : > "$sample_io"
        if [ "$collector_name" = "iotop-static" ]; then
            # iotop-c 1.31 needs -n 2: iteration 1 is baseline (0.00 K/s), iteration 2 is delta over -d interval
            if command -v timeout >/dev/null 2>&1; then
                timeout $((interval + 5)) "$iotop_bin" -b -o -P -k -d "$interval" -n 2 -q </dev/null 2>/dev/null \
                    | parse_iotop_batch_output "$interval" > "$sample_io" || true
            else
                "$iotop_bin" -b -o -P -k -d "$interval" -n 2 -q </dev/null 2>/dev/null \
                    | parse_iotop_batch_output "$interval" > "$sample_io" || true
            fi
        else
            sleep "$interval" &
            wait $! 2>/dev/null || true
            [ "$stopped_by_signal" -ne 0 ] || [ -f "$state_dir/stop.req" ] && break
            _diskwatch_snap_proc_io > "$cur_io"
            awk -F'\t' -v OFS='\t' '
                NR == FNR {
                    pr[$1] = $3 + 0
                    pw[$1] = $4 + 0
                    next
                }
                {
                    pid = $1; comm = $2; rb = $3 + 0; wb = $4 + 0; st = $5
                    dr = (pid in pr) ? (rb - pr[pid]) : 0
                    dw = (pid in pw) ? (wb - pw[pid]) : 0
                    if (dr < 0) dr = 0
                    if (dw < 0) dw = 0
                    rkb = int((dr + 512) / 1024)
                    wkb = int((dw + 512) / 1024)
                    d = (st == "D") ? 1 : 0
                    if (rkb > 0 || wkb > 0 || d == 1) {
                        print pid, comm, rkb, wkb, d
                    }
                }
            ' "$prev_io" "$cur_io" > "$sample_io"
            mv "$cur_io" "$prev_io"
        fi

        [ "$stopped_by_signal" -ne 0 ] || [ -f "$state_dir/stop.req" ] && break

        _diskwatch_snap_diskstats "$watch_file" > "$cur_ds"
        # Compute per-device delta and base-disk totals
        ds_delta_summary=$(awk -F'\t' '
            NR == FNR { pr[$1] = $2 + 0; pw[$1] = $3 + 0; next }
            {
                dev = $1; r = $2 + 0; w = $3 + 0
                dr = (dev in pr) ? (r - pr[dev]) : 0
                dw = (dev in pw) ? (w - pw[dev]) : 0
                if (dr < 0) dr = 0
                if (dw < 0) dw = 0
                rkb = int((dr + 1) / 2)
                wkb = int((dw + 1) / 2)
                if (dr > 0 || dw > 0) {
                    printf "%s(+%dK/+%dK) ", dev, rkb, wkb
                }
            }
        ' "$prev_ds" "$cur_ds" | sed 's/[[:space:]]*$//')

        if [ -n "$ds_delta_summary" ]; then
            # Sum physical base-disk deltas (avoid double-counting partitions + md); POSIX awk (no ARGIND)
            sample_base_rkb=$(awk -F'\t' '
                FNR == 1 { f++ }
                f == 1 { base[$1] = 1; next }
                f == 2 { pr[$1] = $2 + 0; next }
                ($1 in base) {
                    dr = ($1 in pr) ? (($2 + 0) - pr[$1]) : 0
                    if (dr > 0) sum += int((dr + 1) / 2)
                }
                END { print sum + 0 }
            ' "$base_file" "$prev_ds" "$cur_ds")

            sample_base_wkb=$(awk -F'\t' '
                FNR == 1 { f++ }
                f == 1 { base[$1] = 1; next }
                f == 2 { pw[$1] = $3 + 0; next }
                ($1 in base) {
                    dw = ($1 in pw) ? (($3 + 0) - pw[$1]) : 0
                    if (dw > 0) sum += int((dw + 1) / 2)
                }
                END { print sum + 0 }
            ' "$base_file" "$prev_ds" "$cur_ds")

            total_rkb=$((total_rkb + sample_base_rkb))
            total_wkb=$((total_wkb + sample_base_wkb))
            event_count=$((event_count + 1))

            local ts_hms event_procs="" pid comm rkb wkb dstate attr hdd_hit app_name rstatus key label
            ts_hms=$(date '+%H:%M:%S')

            while IFS="$(printf '\t')" read -r pid comm rkb wkb dstate; do
                [ -n "$pid" ] || continue
                [ "$pid" = "$my_pid" ] && continue
                case "$comm" in
                    iotop-static|diskwatch*) continue ;;
                esac

                attr=$(_diskwatch_attribute_pid "$pid" "$comm" "$vols_file" "$watch_file")
                hdd_hit=$(printf '%s\n' "$attr" | awk -F'\t' '{print $1}')
                app_name=$(printf '%s\n' "$attr" | awk -F'\t' '{print $2}')
                rstatus=$(printf '%s\n' "$attr" | awk -F'\t' '{print $3}')

                # Skip processes confirmed to only hold SSD fds
                [ "$hdd_hit" = "0" ] && continue

                if [ -n "$app_name" ]; then
                    key="app:$app_name:$comm"
                    label="$comm [$app_name]"
                else
                    key="proc:$comm"
                    label="$comm"
                fi

                _diskwatch_merge_culprit "$culprits_file" "$key" "$comm" "$app_name" \
                    "$rkb" "$wkb" "$dstate" "$ts_hms" "$rstatus"

                if [ -n "$event_procs" ]; then
                    event_procs="$event_procs, ${label} (+${rkb}K/+${wkb}K)"
                else
                    event_procs="${label} (+${rkb}K/+${wkb}K)"
                fi
            done < "$sample_io"

            [ -n "$event_procs" ] || event_procs="(kernel/short-lived process)"
            printf '%s\t%s\t%s\n' "$ts_hms" "$ds_delta_summary" "$event_procs" >> "$timeline_file"

            # Cap timeline to DISKWATCH_MAX_TIMELINE entries
            if [ "$(wc -l < "$timeline_file")" -gt "$DISKWATCH_MAX_TIMELINE" ]; then
                tail -n "$DISKWATCH_MAX_TIMELINE" "$timeline_file" > "$timeline_file.tmp" && mv "$timeline_file.tmp" "$timeline_file"
            fi
        fi

        mv "$cur_ds" "$prev_ds"

        now_ts=$(date +%s)
        elapsed=$((now_ts - start_ts))
        [ "$elapsed" -gt "$duration" ] && elapsed="$duration"

        # Refresh HDD standby/active state every ~60s on long runs (hdparm -C never wakes sleeping drives)
        if [ $((now_ts - last_power_ts)) -ge 60 ]; then
            power_json=$(get_hdd_power_states_json "$base_file")
            last_power_ts="$now_ts"
        fi

        _diskwatch_write_status_json "running" "$collector_name" "$duration" "$interval" "$elapsed" \
            "$started_at" "$base_file" "$power_json" "$total_rkb" "$total_wkb" "$event_count" \
            "$culprits_file" "$timeline_file" ""
    done

    now_ts=$(date +%s)
    elapsed=$((now_ts - start_ts))
    [ "$elapsed" -gt "$duration" ] && elapsed="$duration"
    power_json=$(get_hdd_power_states_json "$base_file")

    local final_state="done"
    if [ "$stopped_by_signal" -ne 0 ] || [ -f "$state_dir/stop.req" ]; then
        final_state="stopped"
    fi
    rm -f "$state_dir/stop.req"

    _diskwatch_write_status_json "$final_state" "$collector_name" "$duration" "$interval" "$elapsed" \
        "$started_at" "$base_file" "$power_json" "$total_rkb" "$total_wkb" "$event_count" \
        "$culprits_file" "$timeline_file" ""

    release_diskwatch_lock "$lock_owner"
}

####################################################################
# Start detached background HDD monitor
####################################################################
start_diskwatch() {
    local duration="${1:-300}"
    local requested_collector="${2:-auto}"
    local interval collector_pair collector_name iotop_bin lock_owner

    [ -n "$requested_collector" ] || requested_collector="auto"

    if ! diskwatch_validate_duration "$duration"; then
        echo '{"success": false, "error": "Invalid duration (allowed: 30s..12h)"}'
        return 1
    fi

    if ! diskwatch_validate_collector "$requested_collector"; then
        echo '{"success": false, "error": "Invalid collector (allowed: auto, iotop-static, proc-io)"}'
        return 1
    fi

    interval=$(diskwatch_interval_for_duration "$duration")
    lock_owner="dw_$$_$(date +%s)"

    if ! acquire_diskwatch_lock "$lock_owner"; then
        echo '{"success": false, "error": "HDD Monitor is already running"}'
        return 1
    fi

    if [ "$requested_collector" = "proc-io" ]; then
        collector_name="proc-io"
        iotop_bin=""
    else
        collector_pair=$(detect_io_collector)
        collector_name="${collector_pair%%:*}"
        iotop_bin="${collector_pair#*:}"
        if [ "$requested_collector" = "iotop-static" ] && [ "$collector_name" != "iotop-static" ]; then
            release_diskwatch_lock "$lock_owner"
            echo '{"success": false, "error": "iotop-static is not available on this host"}'
            return 1
        fi
    fi

    # Write immediate starting status before detaching
    mkdir -p "$DISKWATCH_STATE_DIR"
    discover_hdd_devices "$DISKWATCH_STATE_DIR"
    local init_power
    init_power=$(get_hdd_power_states_json "$DISKWATCH_STATE_DIR/base_disks.txt")
    : > "$DISKWATCH_STATE_DIR/culprits.tsv"
    : > "$DISKWATCH_STATE_DIR/timeline.tsv"
    _diskwatch_write_status_json "running" "$collector_name" "$duration" "$interval" 0 \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$DISKWATCH_STATE_DIR/base_disks.txt" "$init_power" \
        0 0 0 "$DISKWATCH_STATE_DIR/culprits.tsv" "$DISKWATCH_STATE_DIR/timeline.tsv" ""

    local worker_pid
    (
        trap '' HUP
        trap 'release_diskwatch_lock "'"$lock_owner"'"' EXIT
        _diskwatch_worker_loop "$duration" "$interval" "$collector_name" "$iotop_bin" "$lock_owner"
    ) </dev/null >/dev/null 2>&1 &
    worker_pid=$!
    printf '%s\n' "$worker_pid" > "$DISKWATCH_LOCK_DIR/pid"
    if command -v renice >/dev/null 2>&1; then
        renice 10 "$worker_pid" >/dev/null 2>&1 || true
    fi

    printf '{"success": true, "state": "running", "collector": "%s", "duration": %d, "interval": %d}\n' \
        "$(json_escape "$collector_name")" "$duration" "$interval"
    return 0
}

####################################################################
# Stop running HDD monitor (only signals its own verified lock PID)
####################################################################
stop_diskwatch() {
    local lock_dir="$DISKWATCH_LOCK_DIR"
    local status_file="$DISKWATCH_STATUS_FILE"
    local proc_root="${PROC_ROOT:-/proc}"
    local worker_pid="" child_pid="" p="" waited=0

    mkdir -p "$DISKWATCH_STATE_DIR" 2>/dev/null || true
    : > "$DISKWATCH_STATE_DIR/stop.req" 2>/dev/null || true

    if [ -d "$lock_dir" ]; then
        worker_pid=$(cat "$lock_dir/pid" 2>/dev/null || true)
        case "$worker_pid" in
            ''|*[!0-9]*)
                rm -rf "$lock_dir" 2>/dev/null || true
                ;;
            *)
                if kill -0 "$worker_pid" 2>/dev/null; then
                    # Signal direct children (e.g. in-flight iotop-static or sleep) so worker exits immediately
                    for p in "$proc_root"/[0-9]*/stat; do
                        [ -r "$p" ] || continue
                        child_pid=$(awk -v pp="$worker_pid" 'BEGIN{FS=") "} { split($2, b, " "); if (b[2] == pp) { sub(/ .*/, "", $1); print $1 } }' "$p" 2>/dev/null || true)
                        [ -n "$child_pid" ] && kill -TERM "$child_pid" 2>/dev/null || true
                    done
                    kill -TERM "$worker_pid" 2>/dev/null || true
                    while kill -0 "$worker_pid" 2>/dev/null && [ "$waited" -lt 2 ]; do
                        sleep 1
                        waited=$((waited + 1))
                    done
                    if kill -0 "$worker_pid" 2>/dev/null; then
                        kill -KILL "$worker_pid" 2>/dev/null || true
                    fi
                fi
                rm -rf "$lock_dir" 2>/dev/null || true
                ;;
        esac
    fi

    # Always ensure status file is valid JSON and reflects stopped state
    if [ -f "$status_file" ]; then
        if command -v jq >/dev/null 2>&1 && ! jq -e . "$status_file" >/dev/null 2>&1; then
            rm -f "$status_file" 2>/dev/null || true
        elif grep -q '"state":"running"' "$status_file" 2>/dev/null; then
            sed 's/"state":"running"/"state":"stopped"/' "$status_file" > "$status_file.tmp.$$" \
                && mv "$status_file.tmp.$$" "$status_file"
        fi
    fi

    echo '{"success": true, "state": "stopped", "message": "HDD Monitor stopped"}'
    return 0
}

####################################################################
# Read current/last status JSON (auto-detects idle or stale worker)
####################################################################
get_diskwatch_status_json() {
    local status_file="$DISKWATCH_STATUS_FILE"
    local lock_dir="$DISKWATCH_LOCK_DIR"
    local worker_pid=""

    if [ -f "$status_file" ] && command -v jq >/dev/null 2>&1; then
        if ! jq -e . "$status_file" >/dev/null 2>&1; then
            rm -f "$status_file" 2>/dev/null || true
        fi
    fi

    if [ ! -f "$status_file" ]; then
        local collector_pair collector_name tmp_state power_json devs_json first=1 disk d_esc
        collector_pair=$(detect_io_collector)
        collector_name="${collector_pair%%:*}"
        tmp_state=$(mktemp -d)
        discover_hdd_devices "$tmp_state"
        power_json=$(get_hdd_power_states_json "$tmp_state/base_disks.txt")
        devs_json="["
        while IFS= read -r disk; do
            [ -n "$disk" ] || continue
            d_esc=$(json_escape "$disk")
            [ "$first" -eq 0 ] && devs_json="$devs_json,"
            first=0
            devs_json="$devs_json\"$d_esc\""
        done < "$tmp_state/base_disks.txt"
        devs_json="$devs_json]"
        rm -rf "$tmp_state"
        printf '{"state":"idle","collector":"%s","duration":0,"interval":0,"elapsed":0,"startedAt":"","updatedAt":"","hddDevices":%s,"hddPower":%s,"hddReadKB":0,"hddWriteKB":0,"eventCount":0,"error":"","culprits":[],"timeline":[]}\n' \
            "$(json_escape "$collector_name")" "$devs_json" "$power_json"
        return 0
    fi

    # If status says running but worker PID is gone, clean stale lock and mark stopped
    if grep -q '"state":"running"' "$status_file" 2>/dev/null; then
        worker_pid=$(cat "$lock_dir/pid" 2>/dev/null || true)
        if [ -z "$worker_pid" ] || ! kill -0 "$worker_pid" 2>/dev/null; then
            rm -rf "$lock_dir" 2>/dev/null || true
            sed 's/"state":"running"/"state":"stopped"/' "$status_file" > "$status_file.tmp.$$" \
                && mv "$status_file.tmp.$$" "$status_file"
        fi
    fi

    cat "$status_file"
}
