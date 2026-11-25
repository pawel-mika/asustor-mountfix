#!/usr/bin/env bash
set -e

# Build JS into a temp dir and verify tracked webman/mountfix.js is in sync (without dirtying repo)
TMP_JS_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_JS_DIR"' EXIT
cp -r webman "$TMP_JS_DIR/"
./buildJs.sh "$TMP_JS_DIR" false >/dev/null
diff -u webman/mountfix.js "$TMP_JS_DIR/webman/mountfix.js" || {
    echo "FAIL: webman/mountfix.js is out of sync with mf_*.js sources — run ./buildJs.sh"; exit 1
}

# Check if mountfix.js contains syncBackSelectedApp
grep -q "syncBackSelectedApp" webman/mountfix.js || { echo "FAIL: syncBackSelectedApp missing from mountfix.js"; exit 1; }

# Check if unmount prompt with sync-back exists
grep -q "Unmount & Sync-back" webman/mountfix.js || { echo "FAIL: Unmount & Sync-back button missing from mountfix.js"; exit 1; }

# Check that native ADM msgWindow is used for consistent modal styling
grep -q "AS.ARC.msgWindow" webman/mountfix.js || { echo "FAIL: AS.ARC.msgWindow missing from mountfix.js"; exit 1; }

# Check that unmount is blocked when app is running
grep -q "btnUnmount.setDisabled(running || !mounted)" webman/mountfix.js || { echo "FAIL: unmount button must be disabled when running"; exit 1; }

# Ensure no dead code, debug leftovers, or path typos remain (F9, F17)
for forbidden in "console.log('sync back')" "rsync -au" "window.qq" "getApps(" "..apps/MountFix"; do
    if grep -qF "$forbidden" webman/mountfix.js; then
        echo "FAIL: forbidden leftover '$forbidden' still present in mountfix.js"; exit 1
    fi
done
grep -q "taskIcon: '../apps/MountFix/images/icon-app-task.png'" webman/mountfix.js || { echo "FAIL: fixed taskIcon path missing"; exit 1; }
grep -q "stopMigrationMonitor" webman/mountfix.js || { echo "FAIL: stopMigrationMonitor missing"; exit 1; }

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
let lastAjaxOpts = null;
let createdDialogs = [];
let timeoutCallbacks = [];
let clearedTimeouts = [];

const sandbox = {
    console,
    setTimeout: (fn) => {
        timeoutCallbacks.push(fn);
        return timeoutCallbacks.length;
    },
    clearTimeout: (id) => {
        clearedTimeouts.push(id);
    },
    window: {},
    AS: {
        ARC: {
            util: {
                getUserAppsPath: () => '/portal/apis/apps/',
                getApiUrlWithSid: (url, params) => {
                    if (!params) return url;
                    const qs = Object.keys(params).map((k) => `${k}=${params[k]}`).join('&');
                    return `${url}?${qs}`;
                },
            },
            ajax: (opts) => {
                lastAjaxOpts = opts;
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
        apply: Object.assign,
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

// 6. monitorMigrationStatus: chained setTimeout does NOT finish on progress: 100 with state: 'running', finishes only on state: 'done'
timeoutCallbacks = [];
clearedTimeouts = [];
p = makePage();
let completedCount = 0;
p.monitorMigrationStatus('Copying docker-ce', () => { completedCount += 1; });
assert.strictEqual(timeoutCallbacks.length, 1);
assert.strictEqual(p.maskStack.length, 1);

nextAjaxResponse = {
    success: true,
    result: { app: 'docker-ce', state: 'running', progress: 100, lastLine: '5,242,880 100% 10MB/s', pid: 1234 },
};
timeoutCallbacks[0]();
assert.strictEqual(timeoutCallbacks.length, 2, 'must schedule next setTimeout while state is running even at 100%');
assert.strictEqual(p.maskStack.length, 1, 'must stay masked while state is running');
assert.strictEqual(completedCount, 0);
assert.strictEqual(p.validateCalls.length, 0);

nextAjaxResponse = {
    success: true,
    result: { app: 'docker-ce', state: 'done', progress: 100, lastLine: 'DONE | 100% | Completed', pid: null },
};
timeoutCallbacks[1]();
assert.strictEqual(timeoutCallbacks.length, 2, 'must NOT schedule another setTimeout on state === done');
assert.strictEqual(p.maskStack.length, 0, 'must unmaskAll on state === done');
assert.strictEqual(completedCount, 1);
assert.strictEqual(p.validateCalls.length, 1);

// 7. monitorMigrationStatus: stops polling and surfaces error on state: 'error'
timeoutCallbacks = [];
clearedTimeouts = [];
p = makePage();
p.monitorMigrationStatus('Copying docker-ce');
nextAjaxResponse = {
    success: true,
    result: { app: 'docker-ce', state: 'error', progress: 0, lastLine: 'ERROR | Transfer failed (exit code: 23)', pid: null },
};
timeoutCallbacks[0]();
assert.strictEqual(timeoutCallbacks.length, 1, 'must NOT reschedule on state === error');
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

// 11. unmountSelectedApp "Unmount & Sync-back" skips duplicate confirmation and does NOT run validate() in parallel (F16)
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
assert.strictEqual(p.validateCalls.length, 0, 'Unmount & Sync-back must NOT fire validate() in parallel with sync-back');

// 12. Standalone bindMountAction passes appName to validate(app)
p = makePage();
const validatedApps = [];
p.validate = (appName) => { validatedApps.push(appName); };
nextAjaxResponse = { success: true, message: 'Mounted' };
p.bindMountAction('mount', 'Mounting...', 'Mounted');
assert.deepStrictEqual(validatedApps, ['docker-ce'], 'bindMountAction without callback must call validate(app)');

// 13. validate(appName) passes app query param and does not push onto maskStack (non-blocking)
let lastAjaxUrl = '';
sandbox.AS.ARC.ajax = (opts) => {
    lastAjaxUrl = opts.url;
    origAjax(opts);
};
p = makePage();
p.validate = actionsProto.validate;
nextAjaxResponse = { success: true, apps: [] };
p.validate('docker-ce');
assert(lastAjaxUrl.includes('app=docker-ce'), 'validate(appName) must pass app=docker-ce, got: ' + lastAjaxUrl);
assert.strictEqual(p.maskStack.length, 0, 'validate() must be non-blocking (no modal mask)');

// 14. setMfConfig suspends combo events around setValue (no double validate on open)
const comboEvents = [];
p = makePage();
p.win.down = (sel) => {
    if (sel === 'combo[name=targetVolume]') {
        return {
            getStore: () => ({ loadData() {} }),
            suspendEvents: () => comboEvents.push('suspend'),
            setValue: (v) => comboEvents.push('set:' + v),
            resumeEvents: () => comboEvents.push('resume'),
        };
    }
    if (sel === '#appGrid') return { getStore: () => ({ loadData() {} }) };
    return null;
};
p.setMfConfig({ config: { targetVolume: '/volume2', selectedApps: [] }, apps: [], volumes: [{ volume: '/volume2' }] });
assert.deepStrictEqual(comboEvents, ['suspend', 'set:/volume2', 'resume'], 'setMfConfig must suspend/resume combo events');
sandbox.AS.ARC.ajax = origAjax;

// 15. F9: maskStack is NOT shared on Actions prototype; stopMigrationMonitor cancels active timer
assert.strictEqual(actionsProto.maskStack, undefined, 'maskStack must not live on Actions prototype');
timeoutCallbacks = [];
clearedTimeouts = [];
p = makePage();
p.monitorMigrationStatus('Copying docker-ce');
assert.strictEqual(timeoutCallbacks.length, 1);
p.stopMigrationMonitor();
assert.strictEqual(clearedTimeouts.length, 1, 'stopMigrationMonitor must clear pending setTimeout');
assert.strictEqual(p._pollActive, false);

// 16. F17 & POST-only: mutating calls use POST and migrateSelectedApp sends no bogus config body
p = makePage();
nextAjaxResponse = { success: true, result: { success: true } };
p.migrateSelectedApp(false);
assert.strictEqual(lastAjaxOpts.method, 'POST', 'migrateSelectedApp must use POST');
assert.strictEqual(lastAjaxOpts.params, undefined, 'migrateSelectedApp must not send unused getMfConfig() POST body');

p = makePage();
nextAjaxResponse = { success: true, result: { success: true } };
p.syncBackSelectedApp(null, true);
assert.strictEqual(lastAjaxOpts.method, 'POST', 'syncBackSelectedApp must use POST');

p = makePage();
nextAjaxResponse = { success: true, message: 'Mounted' };
p.bindMountAction('mount', 'Mounting...', 'Mounted');
assert.strictEqual(lastAjaxOpts.method, 'POST', 'bindMountAction must use POST');

p = makePage();
nextAjaxResponse = { success: true };
p.saveConfig();
assert.strictEqual(lastAjaxOpts.method, 'POST', 'saveConfig must use POST');

// 17. Entware relocation warning appears before copying or mounting entware
createdDialogs = [];
p = makePage();
p.selectedApp = { get: (k) => (k === 'name' ? 'entware' : false) };
lastAjaxOpts = null;
p.migrateSelectedApp(false);
assert.strictEqual(lastAjaxOpts, null, 'entware migrate must wait for warning confirmation');
assert.strictEqual(createdDialogs.length, 1);
assert.strictEqual(createdDialogs[0].cfg.title, 'Warning: Relocating Entware');

createdDialogs = [];
p = makePage();
p.selectedApp = { get: (k) => (k === 'name' ? 'entware' : false) };
lastAjaxOpts = null;
p.mountSelectedApp();
assert.strictEqual(lastAjaxOpts, null, 'entware mount must wait for warning confirmation');
assert.strictEqual(createdDialogs.length, 1);
assert.strictEqual(createdDialogs[0].cfg.title, 'Warning: Relocating Entware');
nextAjaxResponse = { success: true, message: 'Mounted' };
createdDialogs[0].cfg.fbar[0].handler();
assert.strictEqual(lastAjaxOpts.method, 'POST', 'confirming entware mount warning must execute POST mount');

// 18. migrateSelectedApp(false) with existsInTarget=true prompts immediately (no pre-flight overlay/AJAX)
createdDialogs = [];
lastAjaxOpts = null;
p = makePage();
p.selectedApp = { get: (k) => (k === 'name' ? 'docker-ce' : k === 'existsInTarget') };
p.migrateSelectedApp(false);
assert.strictEqual(lastAjaxOpts, null, 'existsInTarget=true should prompt before sending migrate AJAX');
assert.strictEqual(p.maskStack.length, 0, 'existsInTarget=true should not mask window before prompt');
assert.strictEqual(createdDialogs.length, 1);
assert.strictEqual(createdDialogs[0].cfg.title, 'Target Directory Exists');

// 19. validate() persists status during flight, clears on finish, and calls record.commit()
timeoutCallbacks = [];
let committed = false;
const statusLog = [];
p = makePage();
p.validate = actionsProto.validate;
p.updateStatus = (msg, isErr, persist) => statusLog.push({ msg, isErr, persist: !!persist });
p.win.down = (sel) => {
    if (sel === 'combo[name=targetVolume]') return { getValue: () => '/volume2' };
    if (sel === '#appGrid') {
        return {
            getStore: () => ({
                findRecord: () => ({ set() {}, commit() { committed = true; } }),
                add() {},
            }),
        };
    }
    return null;
};
nextAjaxResponse = { success: true, apps: [{ name: 'docker-ce', configured: true }] };
p.validate();
assert.strictEqual(statusLog[0].msg, 'Validating...');
assert.strictEqual(statusLog[0].persist, true, 'Validating status must persist until response');
assert.strictEqual(statusLog.at(-1).msg, '', 'Validating status must clear on completion');
assert.strictEqual(committed, true, 'validate() must call record.commit() to clear dirty markers');

// 20. updateActionsUI updates #actionHint for running app and clears for stopped app; setMfConfig sets window title version
let hintHtml = '';
const makeBtn = () => ({ setText() {}, setDisabled() {}, disable() {} });
p = makePage();
p.win.down = (sel) => {
    if (sel === '#actionHint') {
        return {
            update(h) { hintHtml = h; },
        };
    }
    return makeBtn();
};
p.selectedApp = { get: (k) => (k === 'name' ? 'minidlna' : k === 'enabled') };
p.updateActionsUI();
assert(hintHtml.includes('minidlna') && hintHtml.includes('AppCentral'), 'actionHint must explain stopping running app');

p.selectedApp = { get: (k) => (k === 'name' ? 'minidlna' : false) };
p.updateActionsUI();
assert.strictEqual(hintHtml, '&nbsp;', 'actionHint must clear for stopped app');

let verHtml = '';
let setTitleCalled = false;
let sysctlVal = null;
p = makePage();
p.win.setTitle = () => { setTitleCalled = true; };
p.win.down = (sel) => {
    if (sel === '#displayVersion') return { update(h) { verHtml = h; } };
    if (sel === '#chkSysctlTuning') return { setValue(v) { sysctlVal = v; }, getValue: () => sysctlVal };
    if (sel === '#mainPanel') return { getValues: () => ({ targetVolume: '/volume2' }) };
    if (sel === '#appGrid') return { getStore: () => ({ loadData() {}, data: { items: [] } }) };
    return null;
};
p.setMfConfig({ config: { targetVolume: '/volume2', selectedApps: [], enableSysctlTuning: true }, apps: [], volumes: [], version: '0.0.0.111' });
assert.strictEqual(setTitleCalled, false, 'setMfConfig must NOT call win.setTitle (breaks ADM header icon)');
assert.strictEqual(verHtml, 'v0.0.0.111', 'setMfConfig must display version in footer #displayVersion');
assert.strictEqual(sysctlVal, true, 'setMfConfig must set #chkSysctlTuning from config.enableSysctlTuning');
assert.strictEqual(p.getMfConfig().enableSysctlTuning, true, 'getMfConfig must return boolean enableSysctlTuning=true');
sysctlVal = false;
assert.strictEqual(p.getMfConfig().enableSysctlTuning, false, 'getMfConfig must return boolean enableSysctlTuning=false');
EOF
fi

echo "PASS: UI build verification passed."

