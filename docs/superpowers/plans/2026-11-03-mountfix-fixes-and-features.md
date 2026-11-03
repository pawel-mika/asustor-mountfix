# MountFix Safety Fixes and Features Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement safe data synchronization (Sync-back DST->SRC), protected application copying (Copy-to-target SRC->DST with existence guard and `rsync -au`), unmount dialog with Sync-back reminder, repaired configuration parsing, and reliable boot/shutdown mount lifecycle for MountFix on ASUSTOR ADM.

**Architecture:** POSIX shell scripts (`CONTROL/common.sh`, `CONTROL/start-stop.sh`, `webman/scripts/common.sh`) powering CGI endpoints in ADM (`migrate.cgi`, `config.cgi`, `mount.cgi`), controlled by an ExtJS 4/5 desktop frontend (`webman/mf_core.js`, `webman/mf_actions.js`), compiled via `buildJs.sh` and packaged into an APKG using `toolchain/apkg-tools_py3.py`.

**Tech Stack:** POSIX Shell / BusyBox sh, Bash, jq, rsync, ExtJS 4/5 (ASUSTOR Webman SDK), Python 3 packaging tools.

## Global Constraints
- **Zero Destruction**: Never run destructive deletions (`rm -rf` on target/source directories, no `--delete` flag in rsync).
- **Rsync Update Mode**: Always use `-au` (`--archive` and `--update`) to ensure older files from source never overwrite newer files on destination.
- **Strict Inode Check**: Inode equality comparison (`stat -c %d:%i`) must be used to verify mount state.
- **Precondition for Transfer and Sync-Back**: Refuse transfer or sync-back while an application is actively mounted to prevent self-copying and filesystem loop corruption.
- **BusyBox POSIX Compliance**: `CONTROL/start-stop.sh` and `CONTROL/common.sh` must remain fully compatible with BusyBox `/bin/sh`.
- **JSON Contract**: All CGI endpoints must respond with valid JSON: `{"success": true|false, ...}`.

---

### Task 1: Fix configuration parsing & template JSON

**Files:**
- Modify: `CONTROL/common.sh:6-32`
- Modify: `etc/mountfix.conf:1-4`
- Create: `tests/test_config_parsing.sh`

**Interfaces:**
- Consumes: `/usr/local/AppCentral/MountFix/etc/mountfix.conf` (or `$CONFIG_FILE`)
- Produces: `get_mount_configs()` stdout lines: `<SRC>:<TGT>`

- [ ] **Step 1: Write the failing test**

Create `tests/test_config_parsing.sh`:
```bash
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

# Load function and override CONFIG_FILE
source CONTROL/common.sh
CONFIG_FILE="$TEST_CONF"

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x tests/test_config_parsing.sh && ./tests/test_config_parsing.sh`
Expected: FAIL with jq parse error on `etc/mountfix.conf` or failure on Format A.

- [ ] **Step 3: Write minimal implementation**

Update `etc/mountfix.conf`:
```json
{
  "targetVolume": "/volume2",
  "selectedApps": [
    {
      "name": "docker-ce"
    }
  ]
}
```

Update `CONTROL/common.sh`:
```sh
#!/bin/sh

# Function to retrieve enabled mount points from configuration
# In POSIX sh, we cannot return an array. 
# This function prints the results to stdout, one per line.
get_mount_configs() {
    # Allow overriding CONFIG_FILE for tests/runtime flexibility
    local CFG="${CONFIG_FILE:-/usr/local/AppCentral/MountFix/etc/mountfix.conf}"
    local JSON_DATA
    local TARGET_VOL

    # Validate file existence
    if [ ! -f "$CFG" ]; then
        echo "Error: Configuration file not found at $CFG" >&2
        return 1
    fi

    JSON_DATA=$(cat "$CFG")
    TARGET_VOL=$(echo "$JSON_DATA" | jq -r '.targetVolume // empty')

    # Check if targetVolume is valid
    if [ -z "$TARGET_VOL" ] || [ "$TARGET_VOL" = "null" ]; then
        echo "Error: targetVolume is undefined in config" >&2
        return 1
    fi

    # Output formatted strings:
    # Accept if .enabled == true OR if .enabled is missing/null (since selectedApps only contains selected items)
    echo "$JSON_DATA" | jq -r --arg vol "$TARGET_VOL" \
        '.selectedApps[]? | select(.enabled == true or .enabled == null) | "\($vol)/AppCentral/\(.name):/volume1/.@plugins/AppCentral/\(.name)"'
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/test_config_parsing.sh`
Expected: `PASS: Configuration parsing tests passed.`

- [ ] **Step 5: Commit**

```bash
git add CONTROL/common.sh etc/mountfix.conf tests/test_config_parsing.sh
git commit -m "fix: resolve mountfix.conf syntax and allow selectedApps without enabled flag"
```

---

### Task 2: Fix `CONTROL/start-stop.sh` service boot and shutdown lifecycle

**Files:**
- Modify: `CONTROL/start-stop.sh:26-99`
- Modify: `CONTROL/config.json:30-38`
- Create: `tests/test_start_stop.sh`

**Interfaces:**
- Consumes: `get_mount_configs()` from `CONTROL/common.sh`
- Produces: `start-stop.sh start|stop|restart` actions for ADM init system

- [ ] **Step 1: Write the failing test**

Create `tests/test_start_stop.sh`:
```bash
#!/usr/bin/env bash
set -e

# Test 1: Verify config.json boot priority
STOP_ORDER=$(jq -r '.register["boot-priority"]["stop-order"]' CONTROL/config.json)
if [ "$STOP_ORDER" -lt 90 ]; then
    echo "FAIL: stop-order ($STOP_ORDER) must be >= 90 so MountFix shuts down after Docker"
    exit 1
fi

# Test 2: Check syntax of start-stop.sh
sh -n CONTROL/start-stop.sh || { echo "FAIL: Syntax error in start-stop.sh"; exit 1; }

# Test 3: Ensure do_action in start-stop.sh is not commented out
if grep -q '# for ENTRY in $MOUNTS;' CONTROL/start-stop.sh; then
    echo "FAIL: start-stop.sh still has commented do_action loop"
    exit 1
fi

echo "PASS: start-stop.sh verification tests passed."
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x tests/test_start_stop.sh && ./tests/test_start_stop.sh`
Expected: FAIL (stop-order is 2, and loop is commented out).

- [ ] **Step 3: Write minimal implementation**

Update `CONTROL/config.json:30-38`:
```json
  "register": {
    "symbolic-link": {},
    "share-folder": [],
    "boot-priority": {
      "start-order": 2,
      "stop-order": 95
    },
    "port": []
  }
```

Update `CONTROL/start-stop.sh`:
```sh
#!/bin/sh

# 1. Load the common functions:
# - get_mount_configs() to read the config and build the MOUNTS variable
if [ -f "/volume1/.@plugins/AppCentral/MountFix/CONTROL/common.sh" ]; then
    . /volume1/.@plugins/AppCentral/MountFix/CONTROL/common.sh
elif [ -f "$(dirname "$0")/common.sh" ]; then
    . "$(dirname "$0")/common.sh"
fi

# reduce tendency to use SWAP to minimum
sysctl -w vm.swappiness=1 2>/dev/null || true
# force the system to keep file and folder information in RAM
sysctl -w vm.vfs_cache_pressure=10 2>/dev/null || true
# prolong the time after which "dirty" data is written to disk (to 60s)
sysctl -w vm.dirty_writeback_centisecs=6000 2>/dev/null || true
sysctl -w vm.dirty_expire_centisecs=6000 2>/dev/null || true

# get the mount points from config
MOUNTS=$(get_mount_configs)
if [ $? -ne 0 ]; then
    echo "Failed to load configuration from common.sh" >&2
    exit 1
fi

is_mounted() {
    local src="$1"
    local tgt="$2"
    [ -d "$src" ] && [ -d "$tgt" ] || return 1
    local s_ino t_ino
    s_ino=$(stat -c %d:%i "$src" 2>/dev/null) || return 1
    t_ino=$(stat -c %d:%i "$tgt" 2>/dev/null) || return 1
    [ "$s_ino" = "$t_ino" ]
}

# Function to perform the mount/umount action
do_action() {
    ACTION=$1
    echo "$MOUNTS" | while IFS=':' read -r SRC TGT; do
        [ -z "$SRC" ] || [ -z "$TGT" ] && continue

        case "$ACTION" in
            start)
                if [ -d "$SRC" ] && [ -d "$TGT" ]; then
                    if is_mounted "$SRC" "$TGT"; then
                        echo "Already mounted: $SRC -> $TGT"
                    else
                        mount --bind "$SRC" "$TGT"
                        if is_mounted "$SRC" "$TGT"; then
                            echo "Successfully mounted: $SRC -> $TGT"
                        else
                            echo "Error: mount --bind failed for $TGT" >&2
                        fi
                    fi
                else
                    echo "Error: Directory missing - SRC: $SRC or TGT: $TGT" >&2
                fi
                ;;
            stop)
                echo "[$(date)] Checking if services are using $TGT..."

                # 1. Grace period (max 20 seconds) for apps to finish closing
                MAX_WAIT=20
                while [ $MAX_WAIT -gt 0 ]; do
                    if ! fuser -m "$TGT" >/dev/null 2>&1; then
                        break
                    fi
                    echo "Waiting for processes to release $TGT... ($MAX_WAIT s left)"
                    sleep 2
                    MAX_WAIT=$((MAX_WAIT - 2))
                done

                # 2. If after 20s processes are still active, terminate them to release mount
                if [ $MAX_WAIT -le 0 ]; then
                    echo "Timeout reached for $TGT. Terminating remaining processes..."
                    fuser -k -m "$TGT" >/dev/null 2>&1 || true
                    sleep 1
                fi

                # 3. Clean unmount
                sync
                if is_mounted "$SRC" "$TGT"; then
                    umount -l "$TGT" 2>/dev/null || true
                    echo "Unmounted: $TGT"
                fi
                ;;
        esac
    done
}

case "$1" in
    start)
        echo "Starting custom mount binds..."
        do_action "start"
        ;;
    stop)
        echo "Stopping custom mount binds..."
        do_action "stop"
        ;;
    restart)
        $0 stop
        sleep 2
        $0 start
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac

exit 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/test_start_stop.sh`
Expected: `PASS: start-stop.sh verification tests passed.`

- [ ] **Step 5: Commit**

```bash
git add CONTROL/start-stop.sh CONTROL/config.json tests/test_start_stop.sh
git commit -m "fix: restore start-stop.sh mounting logic and configure safe shutdown priority"
```

---

### Task 3: Implement Backend Guardrails for `start_app_transfer` and add `start_app_sync_back`

**Files:**
- Modify: `webman/scripts/common.sh:400-450`
- Modify: `webman/migrate.cgi:1-25`
- Create: `tests/test_sync_back.sh`

**Interfaces:**
- Consumes:
  - `start_app_transfer <targetVolume> <appName> [force]`
  - `start_app_sync_back <targetVolume> <appName>`
- Produces:
  - `migrate.cgi?act=migrate&target=...&app=...[&force=1]`
  - `migrate.cgi?act=sync_back&target=...&app=...`

- [ ] **Step 1: Write the failing test**

Create `tests/test_sync_back.sh`:
```bash
#!/usr/bin/env bash
set -e

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/volume1/.@plugins/AppCentral/testapp"
mkdir -p "$TMP_DIR/volume2/AppCentral/testapp"

echo "original" > "$TMP_DIR/volume1/.@plugins/AppCentral/testapp/file.txt"
echo "modified_on_ssd" > "$TMP_DIR/volume2/AppCentral/testapp/file.txt"
echo "new_on_ssd" > "$TMP_DIR/volume2/AppCentral/testapp/new.txt"

source webman/scripts/common.sh

# Test 1: Check start_app_sync_back exists
type start_app_sync_back >/dev/null 2>&1 || { echo "FAIL: start_app_sync_back not defined"; exit 1; }

# Test 2: Check start_app_transfer uses rsync -au (and not plain -a)
grep -E 'rsync.*-au' webman/scripts/common.sh >/dev/null || { echo "FAIL: rsync in start_app_transfer must use -au"; exit 1; }

# Test 3: Check target existence guard in start_app_transfer
grep -q 'target_exists' webman/scripts/common.sh || { echo "FAIL: start_app_transfer must guard against existing target directory without force"; exit 1; }

echo "PASS: Sync-back and transfer guard tests passed."
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x tests/test_sync_back.sh && ./tests/test_sync_back.sh`
Expected: FAIL (missing `start_app_sync_back` and missing `-au` / `target_exists`).

- [ ] **Step 3: Write minimal implementation**

Update `webman/scripts/common.sh` starting around line 400:
```sh
####################################################################
# Function to start background rsync for selected APP (SRC -> DST)
####################################################################
start_app_transfer() {
    local target_volume="$1"
    local app_name="$2"
    local force="$3"

    if ! validate_target_volume "$target_volume"; then
        echo '{"success": false, "error": "Invalid target volume"}'
        return 1
    fi
    if ! validate_app_name "$app_name"; then
        echo '{"success": false, "error": "Invalid app name"}'
        return 1
    fi

    # CRITICAL: If app is mounted, reject transfer!
    if is_app_bind_mounted "$target_volume" "$app_name"; then
        echo '{"success": false, "error": "Cannot copy while application is mounted. Unmount it first!"}'
        return 1
    fi

    local pipe="/tmp/rsync_progress.pipe"
    local src_vol=$DIR_VOL1
    local src="$src_vol/$DIR_PLUGINS/$DIR_APP_CENTRAL/$app_name"
    local tgt="$target_volume/$DIR_APP_CENTRAL"
    local tgt_app="$tgt/$app_name"

    # Safety check: if target directory already exists and contains files, and force is not "1"
    if [ "$force" != "1" ] && [ -d "$tgt_app" ] && [ "$(ls -A "$tgt_app" 2>/dev/null)" ]; then
        echo '{"success": false, "target_exists": true, "error": "Target directory already contains data. Confirmation required."}'
        return 1
    fi

    # prevent starting multiple transfers for the same app at the same time
    if pgrep -f "rsync.*$app_name" > /dev/null; then
        echo '{"success": false, "error": "Transfer already in progress"}'
        return 1
    fi

    echo "$app_name" > "$STATUS_FILE"
    echo "0% | Starting transfer..." >> "$STATUS_FILE"

    (
        rm -f "$pipe"
        mkfifo "$pipe"
        # Use -au (archive + update flag: skips files that are newer on destination)
        rsync -au --info=progress2 "$src" "$tgt" >> "$pipe" 2>&1 &
        cat "$pipe" | tr '\r' '\n' >> "$STATUS_FILE"
        rm -f "$pipe"

        echo "$app_name" > "$STATUS_FILE"
        if [ $? -eq 0 ]; then
            echo "100% | Completed" >> "$STATUS_FILE"
        else
            echo "ERROR | Transfer failed" >> "$STATUS_FILE"
        fi
    ) &

    echo '{"success": true, "message": "Transfer started in background"}'
}

####################################################################
# Function to sync data BACK from target (SSD) to source (HDD)
# PREREQUISITE: App must NOT be mounted!
####################################################################
start_app_sync_back() {
    local target_volume="$1"
    local app_name="$2"

    if ! validate_target_volume "$target_volume"; then
        echo '{"success": false, "error": "Invalid target volume"}'
        return 1
    fi
    if ! validate_app_name "$app_name"; then
        echo '{"success": false, "error": "Invalid app name"}'
        return 1
    fi

    # CRITICAL SAFETY CHECK: Refuse if app is still mounted!
    if is_app_bind_mounted "$target_volume" "$app_name"; then
        echo '{"success": false, "error": "Cannot sync back while application is mounted. Unmount it first!"}'
        return 1
    fi

    local pipe="/tmp/rsync_syncback_progress.pipe"
    local src="$target_volume/$DIR_APP_CENTRAL/$app_name"
    local tgt="$DIR_VOL1/$DIR_PLUGINS/$DIR_APP_CENTRAL/$app_name"

    if [ ! -d "$src" ]; then
        echo '{"success": false, "error": "Target data directory does not exist on SSD"}'
        return 1
    fi

    if [ ! -d "$tgt" ]; then
        mkdir -p "$tgt"
    fi

    if pgrep -f "rsync.*$app_name" > /dev/null; then
        echo '{"success": false, "error": "Transfer already in progress"}'
        return 1
    fi

    echo "$app_name" > "$STATUS_FILE"
    echo "0% | Starting sync back..." >> "$STATUS_FILE"

    (
        rm -f "$pipe"
        mkfifo "$pipe"
        # Sync back from SSD ($src/) to HDD ($tgt/) with -au (archive + update, no --delete)
        rsync -au --info=progress2 "$src/" "$tgt/" >> "$pipe" 2>&1 &
        cat "$pipe" | tr '\r' '\n' >> "$STATUS_FILE"
        rm -f "$pipe"

        echo "$app_name" > "$STATUS_FILE"
        if [ $? -eq 0 ]; then
            echo "100% | Completed" >> "$STATUS_FILE"
        else
            echo "ERROR | Sync back failed" >> "$STATUS_FILE"
        fi
    ) &

    echo '{"success": true, "message": "Sync back started in background"}'
}
```

Update `webman/migrate.cgi`:
```sh
#!/bin/sh

. ./scripts/common.sh

ACTION=$(get_query_param "$QUERY_STRING" "act")
TARGET_VOL=$(get_query_param "$QUERY_STRING" "target")
APP_PARAM=$(get_query_param "$QUERY_STRING" "app")
FORCE=$(get_query_param "$QUERY_STRING" "force")

send_response() {
    local success="$1"
    local message="$2"
    printf "Content-Type: application/json\r\n\r\n"
    printf "{\"success\": %s, %s}\r\n" "$success" "$message"
    exit 0
}

if [ "$ACTION" = "migrate" ]; then
    RESPONSE=$(start_app_transfer "$TARGET_VOL" "$APP_PARAM" "$FORCE")
    send_response true "\"result\": $RESPONSE"
elif [ "$ACTION" = "sync_back" ]; then
    RESPONSE=$(start_app_sync_back "$TARGET_VOL" "$APP_PARAM")
    send_response true "\"result\": $RESPONSE"
elif [ "$ACTION" = "status" ]; then
    STATUS=$(get_transfer_status_json)
    send_response true "\"result\": $STATUS"
else
    echo '{"success": false, "error": "Invalid action"}'
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/test_sync_back.sh`
Expected: `PASS: Sync-back and transfer guard tests passed.`

- [ ] **Step 5: Commit**

```bash
git add webman/scripts/common.sh webman/migrate.cgi tests/test_sync_back.sh
git commit -m "feat: implement start_app_sync_back and transfer guardrails in backend"
```

---

### Task 4: UI Updates: Wire `btnSyncBack`, guard `btnCopyToTarget`, add Unmount Sync-Back prompt

**Files:**
- Modify: `webman/mf_actions.js`
- Modify: `webman/mf_core.js`
- Create: `tests/test_ui_build.sh`

**Interfaces:**
- Consumes: Backend endpoints `migrate.cgi?act=migrate` & `migrate.cgi?act=sync_back`
- Produces: Built `webman/mountfix.js` through `buildJs.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_ui_build.sh`:
```bash
#!/usr/bin/env bash
set -e

# Run JS build
./buildJs.sh

# Check if mountfix.js contains syncBackSelectedApp
grep -q "syncBackSelectedApp" webman/mountfix.js || { echo "FAIL: syncBackSelectedApp missing from mountfix.js"; exit 1; }

# Check if unmount prompt with sync-back exists
grep -q "Sync-back" webman/mountfix.js || { echo "FAIL: Sync-back unmount prompt missing from mountfix.js"; exit 1; }

# Ensure no dead console.log('sync back') stub remains
if grep -q "console.log('sync back')" webman/mountfix.js; then
    echo "FAIL: console.log('sync back') stub still present"; exit 1
fi

echo "PASS: UI build verification passed."
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x tests/test_ui_build.sh && ./tests/test_ui_build.sh`
Expected: FAIL (`syncBackSelectedApp` missing, `console.log('sync back')` present).

- [ ] **Step 3: Write minimal implementation**

In `webman/mf_actions.js`:
1. Update `migrateSelectedApp`:
```javascript
    migrateSelectedApp: function (force) {
        var page = this;
        var actionMsg = 'Copying application...';
        var target = page.getSelectedVolume();
        var app = page.selectedApp && page.selectedApp.data && page.selectedApp.data.name;

        if (!target || !app) {
            page.updateStatus('Error: Select volume and application first', true);
            return;
        }

        var params = { act: 'migrate', target: target, app: app };
        if (force) {
            params.force = '1';
        }

        page.maskWindow(actionMsg);
        AS.ARC.ajax({
            url: AS.ARC.util.getApiUrlWithSid(page.migrateApiUrl, params),
            params: Ext.encode(page.getMfConfig()),
            success: function (json) {
                var res = json.result || {};
                if (res.target_exists && !force) {
                    page.unmaskWindow(actionMsg);
                    Ext.Msg.confirm(
                        'Target Directory Exists',
                        'Folder docelowy dla ' + app + ' na woluminie ' + target + ' już zawiera dane.<br><br>Czy na pewno chcesz kontynuować kopiowanie? (Użyty zostanie bezpieczny tryb aktualizacji rsync -au, pomijający pliki nowsze na SSD).',
                        function (btn) {
                            if (btn === 'yes') {
                                page.migrateSelectedApp(true);
                            }
                        }
                    );
                    return;
                }
                if (json.success && (res.success || res.success === undefined)) {
                    page.updateStatus('Copying started successfully', false);
                    page.monitorMigrationStatus();
                } else {
                    page.unmaskWindow(actionMsg);
                    page.updateStatus('Error: ' + (res.error || json.error || 'Failed to start copying'), true);
                }
            },
            failure: function () {
                page.updateStatus('Error: Unable to start copying', true);
                page.unmaskWindow(actionMsg);
            },
        });
    },
```

2. Add `syncBackSelectedApp`:
```javascript
    syncBackSelectedApp: function (callbackOnComplete) {
        var page = this;
        var target = page.getSelectedVolume();
        var app = page.selectedApp && page.selectedApp.get('name');

        if (!target || !app) {
            page.updateStatus('Error: Select volume and application first', true);
            return;
        }

        var actionMsg = 'Syncing back ' + app + '...';
        page.maskWindow(actionMsg);

        AS.ARC.ajax({
            url: AS.ARC.util.getApiUrlWithSid(page.migrateApiUrl, { act: 'sync_back', target: target, app: app }),
            method: 'GET',
            success: function (json) {
                var res = json.result || {};
                if (json.success && (res.success || res.success === undefined)) {
                    page.updateStatus('Sync back started successfully', false);
                    page.monitorMigrationStatus(callbackOnComplete);
                } else {
                    page.unmaskWindow(actionMsg);
                    page.updateStatus('Error: ' + (res.error || json.error || 'Failed to start sync back'), true);
                }
            },
            failure: function () {
                page.unmaskWindow(actionMsg);
                page.updateStatus('Error: Unable to start sync back', true);
            },
        });
    },
```

3. Update `monitorMigrationStatus`:
```javascript
    monitorMigrationStatus: function (callbackOnComplete) {
        var page = this;
        var actionMsg = 'Monitoring transfer status...';
        page.maskWindow(actionMsg);

        var intervalId = setInterval(function () {
            AS.ARC.ajax({
                url: AS.ARC.util.getApiUrlWithSid(page.migrateApiUrl, { act: 'status' }),
                method: 'GET',
                success: function (json) {
                    const { app, progress } = json.result || {};
                    const currentAppName = page.selectedApp && page.selectedApp.data && page.selectedApp.data.name;
                    const finished = progress == 100 && app === currentAppName;
                    if (json.success) {
                        page.updateStatus('Transfer: ' + app + ' - ' + progress + '%', false);
                        if (finished) {
                            clearInterval(intervalId);
                            page.unmaskWindow(actionMsg);
                            page.validate();
                            if (typeof callbackOnComplete === 'function') {
                                callbackOnComplete();
                            }
                        }
                    } else {
                        page.updateStatus('Error: ' + json.message, true);
                        clearInterval(intervalId);
                        page.unmaskWindow(actionMsg);
                    }
                },
                failure: function () {
                    page.updateStatus('Error: Unable to check status', true);
                    clearInterval(intervalId);
                    page.unmaskWindow(actionMsg);
                },
            });
        }, 500);
    },
```

4. Update `unmountSelectedApp`:
```javascript
    unmountSelectedApp: function () {
        var page = this;
        var app = page.selectedApp && page.selectedApp.get('name');
        if (!app) {
            page.updateStatus('Error: Select an application to unmount', true);
            return;
        }

        Ext.Msg.show({
            title: 'Odmontowanie ' + app,
            msg: 'Aplikacja <b>' + app + '</b> zostanie odmontowana z woluminu SSD.<br><br>Czy chcesz najpierw wykonać <b>Sync-back</b> (zaktualizować dysk źródłowy danymi z SSD)?',
            buttons: Ext.Msg.YESNOCANCEL,
            buttonText: {
                yes: 'Sync-back i Odmontuj',
                no: 'Tylko odmontuj',
                cancel: 'Anuluj',
            },
            fn: function (btn) {
                if (btn === 'yes') {
                    // 1. First run sync-back, then on success trigger unmount
                    page.syncBackSelectedApp(function () {
                        page.bindMountAction('unmount', 'Unmounting...', 'Unmounted successfully');
                    });
                } else if (btn === 'no') {
                    // 2. Unmount directly without sync-back
                    page.bindMountAction('unmount', 'Unmounting...', 'Unmounted successfully');
                }
            },
        });
    },
```

In `webman/mf_core.js`:
- Connect `btnSyncBack`:
```javascript
{
    xtype: 'button',
    text: 'Sync back',
    itemId: 'btnSyncBack',
    handler: function () {
        fn.syncBackSelectedApp();
    },
},
```
- Remove or hide `btnBackupTarget` per user preference (avoids confusing tar.gz clutter).
- Run `./buildJs.sh` to compile `webman/mountfix.js`.

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/test_ui_build.sh`
Expected: `PASS: UI build verification passed.`

- [ ] **Step 5: Commit**

```bash
git add webman/mf_actions.js webman/mf_core.js webman/mountfix.js tests/test_ui_build.sh
git commit -m "feat: wire Sync-back action, add overwrite confirmation and unmount prompt"
```

---

### Task 5: Cleanup dead CGI stubs and verify packaging

**Files:**
- Delete: `webman/setup.cgi`, `webman/progress.cgi`
- Modify: `build.sh` (make non-interactive if sudo not required)
- Create: `tests/test_end_to_end_build.sh`

**Interfaces:**
- Consumes: Repository tree
- Produces: Packaged APKG file via `toolchain/apkg-tools_py3.py`

- [ ] **Step 1: Write test for package build validation**

Create `tests/test_end_to_end_build.sh`:
```bash
#!/usr/bin/env bash
set -e

# Verify required directories
[ -d "CONTROL" ] || { echo "CONTROL missing"; exit 1; }
[ -d "webman" ] || { echo "webman missing"; exit 1; }
[ -d "etc" ] || { echo "etc missing"; exit 1; }

# Verify obsolete files are removed
[ ! -f "webman/setup.cgi" ] || { echo "webman/setup.cgi should be removed"; exit 1; }
[ ! -f "webman/progress.cgi" ] || { echo "webman/progress.cgi should be removed"; exit 1; }

# Test python packaging tool directly
TMP_PKG_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_PKG_DIR"' EXIT

cp -r CONTROL "$TMP_PKG_DIR/"
cp -r webman "$TMP_PKG_DIR/"
cp -r etc "$TMP_PKG_DIR/"
./buildJs.sh "$TMP_PKG_DIR" true

python3 ./toolchain/apkg-tools_py3.py create "$TMP_PKG_DIR/" --destination "$TMP_PKG_DIR/"
ls "$TMP_PKG_DIR"/*.apk >/dev/null 2>&1 || { echo "FAIL: APK package creation failed"; exit 1; }

echo "PASS: End-to-end packaging check passed."
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x tests/test_end_to_end_build.sh && ./tests/test_end_to_end_build.sh`
Expected: FAIL (dead CGI files still exist).

- [ ] **Step 3: Remove dead files and adjust `build.sh`**

Delete dead CGI files:
```bash
git rm webman/setup.cgi webman/progress.cgi
```

In `build.sh`, update lines 7-10 so sudo is only used if writing to `$OUT_FOLDER` requires elevated permissions:
```bash
if [ ! -w "$OUT_FOLDER" ] && [ -d "$OUT_FOLDER" ]; then
    if [ "$EUID" -ne 0 ]; then
        echo "Re-running script with sudo for write permissions to $OUT_FOLDER..."
        exec sudo "$0" "$@"
    fi
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/test_end_to_end_build.sh`
Expected: `PASS: End-to-end packaging check passed.`

- [ ] **Step 5: Commit**

```bash
git add build.sh tests/test_end_to_end_build.sh
git commit -m "chore: remove obsolete CGI stubs and verify APK packaging"
```

---

### Task 6: Execute Full Test Suite and Verification

**Files:**
- Test: `tests/test_config_parsing.sh`
- Test: `tests/test_start_stop.sh`
- Test: `tests/test_sync_back.sh`
- Test: `tests/test_ui_build.sh`
- Test: `tests/test_end_to_end_build.sh`

- [ ] **Step 1: Execute all tests**

```bash
for t in tests/test_*.sh; do
    echo "=== Running $t ==="
    ./"$t"
done
```
Expected: All 5 test suites pass with code 0.

- [ ] **Step 2: Verify git status**

Run: `git status`
Expected: Working tree clean, all commits created.
