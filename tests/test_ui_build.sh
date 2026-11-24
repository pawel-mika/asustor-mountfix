#!/usr/bin/env bash
set -e

# Run JS build
./buildJs.sh

# Check if mountfix.js contains syncBackSelectedApp
grep -q "syncBackSelectedApp" webman/mountfix.js || { echo "FAIL: syncBackSelectedApp missing from mountfix.js"; exit 1; }

# Check if unmount prompt with sync-back exists
grep -q "Unmount & Sync-back" webman/mountfix.js || { echo "FAIL: Unmount & Sync-back button missing from mountfix.js"; exit 1; }

# Check that native ADM msgWindow is used for consistent modal styling
grep -q "AS.ARC.msgWindow" webman/mountfix.js || { echo "FAIL: AS.ARC.msgWindow missing from mountfix.js"; exit 1; }

# Check that unmount is blocked when app is running
grep -q "btnUnmount.setDisabled(running || !mounted)" webman/mountfix.js || { echo "FAIL: unmount button must be disabled when running"; exit 1; }

# Ensure no dead console.log('sync back') stub remains
if grep -q "console.log('sync back')" webman/mountfix.js; then
    echo "FAIL: console.log('sync back') stub still present"; exit 1
fi

# Check that Target Directory Exists prompt helper is present and used on failure/success
grep -q "promptTargetExists" webman/mountfix.js || { echo "FAIL: promptTargetExists missing from mountfix.js"; exit 1; }
grep -q "failure: function (json)" webman/mountfix.js || { echo "FAIL: failure(json) payload handler missing from mountfix.js"; exit 1; }

# Verify AS.ARC.ajax failure(d) payload handling in MountFix.Actions when node is available
if command -v node >/dev/null 2>&1; then
    node - <<'EOF'
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');

let actionsProto = null;
let nextAjaxResponse = null;
let createdDialogs = [];

const sandbox = {
    console,
    setInterval: () => 1,
    clearInterval: () => {},
    window: {},
    AS: {
        ARC: {
            util: {
                getUserAppsPath: () => '/portal/apis/apps/',
                getApiUrlWithSid: (url) => url,
            },
            ajax: (opts) => {
                // Simulate ADM AS.ARC.ajax: top-level success===false routes to options.failure(d)
                if (nextAjaxResponse && nextAjaxResponse.success === false) {
                    opts.failure && opts.failure(nextAjaxResponse);
                } else {
                    opts.success && opts.success(nextAjaxResponse);
                }
            },
        },
    },
    Ext: {
        define: (name, proto) => { actionsProto = proto; },
        encode: JSON.stringify,
        defer: () => {},
        Array: {
            remove: (arr, item) => {
                const idx = arr.indexOf(item);
                if (idx !== -1) arr.splice(idx, 1);
            },
        },
        String: { htmlEncode: (s) => String(s) },
        ClassManager: { isCreated: (cls) => cls === 'AS.ARC.msgWindow' },
        create: (cls, cfg) => {
            const dlg = { cls, cfg, shown: false, show() { this.shown = true; }, close() {} };
            createdDialogs.push(dlg);
            return dlg;
        },
        Msg: { confirm: () => {}, show: () => {} },
    },
};

vm.runInNewContext(fs.readFileSync('webman/mf_actions.js', 'utf8'), sandbox);
assert(actionsProto, 'MountFix.Actions definition not captured');

function makePage() {
    const statuses = [];
    const page = Object.assign({}, actionsProto, {
        maskStack: [],
        statuses,
        selectedApp: { get: (k) => (k === 'name' ? 'docker-ce' : false) },
        win: {
            el: { mask() {}, unmask() {} },
            down: (sel) => {
                if (sel === 'combo[name=targetVolume]') return { getValue: () => '/volume2' };
                if (sel === '#mainPanel') return { getValues: () => ({ targetVolume: '/volume2' }) };
                if (sel === '#appGrid') return { getStore: () => ({ data: { items: [] } }) };
                return null;
            },
        },
        updateStatus(msg, isErr) { statuses.push({ msg, isErr }); },
    });
    return page;
}

// 1. migrateSelectedApp: failure({success:false, result:{target_exists:true}}) opens msgWindow and unmasks
createdDialogs = [];
let p = makePage();
nextAjaxResponse = { success: false, result: { success: false, target_exists: true, error: 'Target exists' } };
p.migrateSelectedApp(false);
assert.strictEqual(p.maskStack.length, 0, 'migrate target_exists should unmask');
assert.strictEqual(createdDialogs.length, 1, 'migrate target_exists should open AS.ARC.msgWindow');
assert.strictEqual(createdDialogs[0].shown, true);
assert.strictEqual(createdDialogs[0].cfg.title, 'Target Directory Exists');

// 2. migrateSelectedApp: failure({success:false, result:{error:'...'}}) surfaces backend error
p = makePage();
nextAjaxResponse = { success: false, result: { success: false, error: 'Cannot copy while application is mounted. Unmount it first!' } };
p.migrateSelectedApp(false);
assert.strictEqual(p.maskStack.length, 0);
assert.strictEqual(p.statuses.at(-1).msg, 'Error: Cannot copy while application is mounted. Unmount it first!');
assert.strictEqual(p.statuses.at(-1).isErr, true);

// 3. syncBackSelectedApp: failure({success:false, result:{error:'...'}}) surfaces backend error
p = makePage();
nextAjaxResponse = { success: false, result: { success: false, error: 'Target data directory does not exist on SSD' } };
p.syncBackSelectedApp();
assert.strictEqual(p.maskStack.length, 0);
assert.strictEqual(p.statuses.at(-1).msg, 'Error: Target data directory does not exist on SSD');
assert.strictEqual(p.statuses.at(-1).isErr, true);

// 4. bindMountAction: failure({success:false, error:'...'}) surfaces backend error
p = makePage();
nextAjaxResponse = { success: false, error: 'mount --bind failed: busy' };
p.bindMountAction('mount', 'Mounting...', 'Mounted');
assert.strictEqual(p.maskStack.length, 0);
assert.strictEqual(p.statuses.at(-1).msg, 'Error: mount --bind failed: busy');
assert.strictEqual(p.statuses.at(-1).isErr, true);

// 5. saveConfig: failure({success:false, error:'...'}) surfaces backend error and unmasks
p = makePage();
nextAjaxResponse = { success: false, error: 'Failed to save config' };
p.saveConfig();
assert.strictEqual(p.maskStack.length, 0);
assert.strictEqual(p.statuses.at(-1).msg, 'Error: Failed to save config');
assert.strictEqual(p.statuses.at(-1).isErr, true);
EOF
fi

echo "PASS: UI build verification passed."

