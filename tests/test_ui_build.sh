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

# Ensure no dead console.log('sync back') stub or stale rsync -au text remains
if grep -q "console.log('sync back')" webman/mountfix.js; then
    echo "FAIL: console.log('sync back') stub still present"; exit 1
fi
if grep -q "rsync -au" webman/mountfix.js; then
    echo "FAIL: stale 'rsync -au' wording still present in mountfix.js"; exit 1
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
let intervalCallbacks = [];
let clearedIntervals = [];

const sandbox = {
    console,
    setInterval: (fn) => {
        intervalCallbacks.push(fn);
        return intervalCallbacks.length;
    },
    clearInterval: (id) => {
        clearedIntervals.push(id);
    },
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
    const validateCalls = [];
    const page = Object.assign({}, actionsProto, {
        maskStack: [],
        statuses,
        validateCalls,
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
        validate() { validateCalls.push(true); },
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

// 3. syncBackSelectedApp(null, true): failure({success:false, result:{error:'...'}}) surfaces backend error
p = makePage();
nextAjaxResponse = { success: false, result: { success: false, error: 'Target data directory does not exist on SSD' } };
p.syncBackSelectedApp(null, true);
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

// 6. monitorMigrationStatus: does NOT finish on progress: 100 with state: 'running', finishes only on state: 'done'
intervalCallbacks = [];
clearedIntervals = [];
p = makePage();
let completedCount = 0;
p.monitorMigrationStatus('Copying docker-ce', () => { completedCount += 1; });
assert.strictEqual(intervalCallbacks.length, 1);
assert.strictEqual(p.maskStack.length, 1);

nextAjaxResponse = {
    success: true,
    result: { app: 'docker-ce', state: 'running', progress: 100, lastLine: '5,242,880 100% 10MB/s', pid: 1234 },
};
intervalCallbacks[0]();
assert.strictEqual(clearedIntervals.length, 0, 'must NOT clear interval while state is running even at 100%');
assert.strictEqual(p.maskStack.length, 1, 'must stay masked while state is running');
assert.strictEqual(completedCount, 0);
assert.strictEqual(p.validateCalls.length, 0);

nextAjaxResponse = {
    success: true,
    result: { app: 'docker-ce', state: 'done', progress: 100, lastLine: 'DONE | 100% | Completed', pid: null },
};
intervalCallbacks[0]();
assert.strictEqual(clearedIntervals.length, 1, 'must clear interval on state === done');
assert.strictEqual(p.maskStack.length, 0, 'must unmaskAll on state === done');
assert.strictEqual(completedCount, 1);
assert.strictEqual(p.validateCalls.length, 1);

// 7. monitorMigrationStatus: stops polling and surfaces error on state: 'error'
intervalCallbacks = [];
clearedIntervals = [];
p = makePage();
p.monitorMigrationStatus('Copying docker-ce');
nextAjaxResponse = {
    success: true,
    result: { app: 'docker-ce', state: 'error', progress: 0, lastLine: 'ERROR | Transfer failed (exit code: 23)', pid: null },
};
intervalCallbacks[0]();
assert.strictEqual(clearedIntervals.length, 1, 'must clear interval on state === error');
assert.strictEqual(p.maskStack.length, 0, 'must unmaskAll on state === error');
assert.strictEqual(p.statuses.at(-1).isErr, true);
assert(p.statuses.at(-1).msg.includes('ERROR | Transfer failed'));

// 8. promptTargetExists explains mirror mode (--delete) without rsync -au
createdDialogs = [];
p = makePage();
p.promptTargetExists('docker-ce', '/volume2');
assert.strictEqual(createdDialogs.length, 1);
assert(createdDialogs[0].cfg.asItems[0].value.includes('--delete'));
assert(!createdDialogs[0].cfg.asItems[0].value.includes('rsync -au'));

// 9. syncBackSelectedApp() without skipConfirm shows mirror-mode confirmation before AJAX
createdDialogs = [];
let ajaxCalls = 0;
const origAjax = sandbox.AS.ARC.ajax;
sandbox.AS.ARC.ajax = (opts) => {
    ajaxCalls += 1;
    origAjax(opts);
};
p = makePage();
nextAjaxResponse = { success: false, result: { success: false, error: 'Blocked by running process' } };
p.syncBackSelectedApp();
assert.strictEqual(ajaxCalls, 0, 'syncBackSelectedApp without skipConfirm must wait for confirmation');
assert.strictEqual(createdDialogs.length, 1);
assert.strictEqual(createdDialogs[0].cfg.title, 'Sync back: docker-ce');
assert(createdDialogs[0].cfg.asItems[0].value.includes('--delete'));
assert(createdDialogs[0].cfg.asItems[0].value.includes('identical to SSD'));
createdDialogs[0].cfg.fbar[0].handler();
assert.strictEqual(ajaxCalls, 1, 'confirming Sync back dialog must trigger AJAX');
assert.strictEqual(p.statuses.at(-1).msg, 'Error: Blocked by running process');

// 10. syncBackSelectedApp(null, true) skips dialog and triggers AJAX immediately
createdDialogs = [];
ajaxCalls = 0;
p = makePage();
p.syncBackSelectedApp(null, true);
assert.strictEqual(createdDialogs.length, 0, 'skipConfirm=true must not open a second confirmation dialog');
assert.strictEqual(ajaxCalls, 1);

// 11. unmountSelectedApp "Unmount & Sync-back" skips duplicate confirmation
createdDialogs = [];
ajaxCalls = 0;
p = makePage();
p.selectedApp = { get: (k) => (k === 'name' ? 'docker-ce' : false) };
p.unmountSelectedApp();
assert.strictEqual(createdDialogs.length, 1, 'unmountSelectedApp opens Unmount dialog');
assert(createdDialogs[0].cfg.asItems[0].value.includes('--delete'));
nextAjaxResponse = { success: true, message: 'Unmounted' };
// Click "Unmount & Sync-back" -> calls bindMountAction('unmount', ..., cb), then cb calls syncBackSelectedApp(null, true)
createdDialogs[0].cfg.fbar[0].handler();
assert.strictEqual(createdDialogs.length, 1, 'Unmount & Sync-back must not open a second confirmation dialog');
assert.strictEqual(ajaxCalls, 2, 'Should have called mount.cgi unmount + migrate.cgi sync_back');
sandbox.AS.ARC.ajax = origAjax;
EOF
fi

echo "PASS: UI build verification passed."

