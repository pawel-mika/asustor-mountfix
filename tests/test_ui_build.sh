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
grep -q "btnUnmount.setDisabled(validating || running || !mounted)" webman/mountfix.js || { echo "FAIL: unmount button must be disabled when validating or running"; exit 1; }

# Ensure no dead code, debug leftovers, or path typos remain (F9, F17)
for forbidden in "console.log('sync back')" "rsync -au" "window.qq" "getApps(" "..apps/MountFix"; do
    if grep -qF "$forbidden" webman/mountfix.js; then
        echo "FAIL: forbidden leftover '$forbidden' still present in mountfix.js"; exit 1
    fi
done
grep -q "taskIcon: '../apps/MountFix/images/icon-app-task.png'" webman/mountfix.js || { echo "FAIL: fixed taskIcon path missing"; exit 1; }
grep -q "stopMigrationMonitor" webman/mountfix.js || { echo "FAIL: stopMigrationMonitor missing"; exit 1; }
grep -q "exTitleButtons:" webman/mountfix.js || { echo "FAIL: ADM exTitleButtons config missing"; exit 1; }
grep -q "cls: 'x-tool-question'" webman/mountfix.js || { echo "FAIL: ADM x-tool-question help icon class missing"; exit 1; }
grep -q "this.win.on('afterrender'" webman/mountfix.js || { echo "FAIL: win.on('afterrender') missing (must not shadow AS.ARC.appWindow listeners)"; exit 1; }
grep -q "this.win.on('beforeclose'" webman/mountfix.js || { echo "FAIL: win.on('beforeclose') missing"; exit 1; }
if grep -qF "Ps.initialize" webman/mountfix.js; then
    echo "FAIL: manual Ps.initialize(win.body.dom) must be removed (ADM handles Ps globally)"; exit 1
fi
if grep -qF "btnHelp" webman/mountfix.js; then
    echo "FAIL: footer btnHelp button must not be present (use exTitleButtons x-tool-question)"; exit 1
fi
AJAX_CALLS=$(grep -c "AS\.ARC\.ajax({" webman/mf_actions.js)
FAILURE_RET=$(grep -c "enableFailureReturn: true" webman/mf_actions.js)
[ "$AJAX_CALLS" -eq "$FAILURE_RET" ] || { echo "FAIL: every AS.ARC.ajax call in mf_actions.js must set enableFailureReturn: true ($FAILURE_RET/$AJAX_CALLS)"; exit 1; }

DW_AJAX_CALLS=$(grep -c "AS\.ARC\.ajax({" webman/mf_diskwatch.js)
DW_FAILURE_RET=$(grep -c "enableFailureReturn: true" webman/mf_diskwatch.js)
[ "$DW_AJAX_CALLS" -eq "$DW_FAILURE_RET" ] || { echo "FAIL: every AS.ARC.ajax call in mf_diskwatch.js must set enableFailureReturn: true ($DW_FAILURE_RET/$DW_AJAX_CALLS)"; exit 1; }

grep -q "stopDiskwatchPolling" webman/mountfix.js || { echo "FAIL: stopDiskwatchPolling missing from mountfix.js"; exit 1; }
grep -q "HDD Monitor" webman/mountfix.js || { echo "FAIL: HDD Monitor tab missing from mountfix.js"; exit 1; }
grep -q "value: 3600" webman/mountfix.js || { echo "FAIL: 1h duration preset missing from mountfix.js"; exit 1; }

# Check that Target Directory Exists prompt helper is present and used on failure/success
grep -q "promptTargetExists" webman/mountfix.js || { echo "FAIL: promptTargetExists missing from mountfix.js"; exit 1; }
grep -q "failure: function (json)" webman/mountfix.js || { echo "FAIL: failure(json) payload handler missing from mountfix.js"; exit 1; }
grep -q "itemId: 'btnRefresh'" webman/mountfix.js || { echo "FAIL: manual Refresh button (#btnRefresh) missing from mountfix.js"; exit 1; }
grep -q "mode: 'fast'" webman/mountfix.js || { echo "FAIL: two-tier mode=fast missing from mountfix.js"; exit 1; }
grep -q "mode: 'sizes'" webman/mountfix.js || { echo "FAIL: two-tier mode=sizes missing from mountfix.js"; exit 1; }
grep -q "formatTransferProgress" webman/mountfix.js || { echo "FAIL: formatTransferProgress missing from mountfix.js"; exit 1; }
grep -q "HDD-only NAS" webman/mountfix.js || { echo "FAIL: HDD-only NAS note missing from Quick Guide in mountfix.js"; exit 1; }

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

// 21. showHelpDialog opens scrollable AS.ARC.subWindow (when available) or msgWindow fallback with GitHub link
createdDialogs = [];
sandbox.Ext.ClassManager.isCreated = (cls) => cls === 'AS.ARC.subWindow' || cls === 'AS.ARC.msgWindow';
p = makePage();
p.showHelpDialog();
assert.strictEqual(createdDialogs.length, 1, 'showHelpDialog must open AS.ARC.subWindow');
assert.strictEqual(createdDialogs[0].cls, 'AS.ARC.subWindow');
assert.strictEqual(createdDialogs[0].shown, true);
assert.strictEqual(createdDialogs[0].cfg.title, 'MountFix Quick Guide');
assert.strictEqual(createdDialogs[0].cfg.items[0].autoScroll, true, 'Help dialog panel must be scrollable');
assert(createdDialogs[0].cfg.items[0].html.includes('https://github.com/pawel-mika/asustor-mountfix#readme'), 'Help dialog must include GitHub docs link');

// 22. Actions are disabled while validate() is in flight and re-enabled on completion (success or failure)
const btnStates = {};
const makeTrackedBtn = (id) => ({
    setText() {},
    setDisabled(v) { btnStates[id] = !!v; },
    disable() { btnStates[id] = true; },
});
let deferredAjax = null;
sandbox.AS.ARC.ajax = (opts) => { deferredAjax = opts; };
p = makePage();
p.validate = actionsProto.validate;
p.updateActionsUI = actionsProto.updateActionsUI;
p._validatingCount = 0;
p.selectedApp = { get: (k) => (k === 'name' ? 'docker-ce' : k === 'existsInTarget') };
p.win.down = (sel) => {
    if (sel === 'combo[name=targetVolume]') return { getValue: () => '/volume2' };
    if (sel === '#btnCopyToTarget') return makeTrackedBtn('copy');
    if (sel === '#btnMount') return makeTrackedBtn('mount');
    if (sel === '#btnUnmount') return makeTrackedBtn('unmount');
    if (sel === '#btnSyncBack') return makeTrackedBtn('sync');
    if (sel === '#actionHint') return { update() {} };
    if (sel === '#appGrid') return { getStore: () => ({ findRecord: () => null, add() {} }) };
    return null;
};
p.validate();
assert.strictEqual(p._validatingCount, 1, '_validatingCount must increment while validate is in flight');
assert.strictEqual(btnStates.copy, true, 'Copy must be disabled while validating');
assert.strictEqual(btnStates.mount, true, 'Mount must be disabled while validating');
assert.strictEqual(btnStates.unmount, true, 'Unmount must be disabled while validating');
assert.strictEqual(btnStates.sync, true, 'Sync back must be disabled while validating');
deferredAjax.failure({ success: false });
assert.strictEqual(p._validatingCount, 0, '_validatingCount must decrement on validate failure');
assert.strictEqual(btnStates.copy, false, 'Copy must re-enable after validate finishes for stopped unmounted app');
assert.strictEqual(btnStates.mount, false, 'Mount must re-enable after validate finishes when existsInTarget=true');
sandbox.AS.ARC.ajax = origAjax;

// 23. MountFix.Diskwatch unit tests (formatting, 30s..12h presets, polling lifecycle, and failure recovery)
let dwProto = null;
const dwSandbox = Object.assign({}, sandbox, {
    Ext: Object.assign({}, sandbox.Ext, {
        isArray: Array.isArray,
        define: (name, proto) => { dwProto = proto; },
        create: (cls, cfg) => ({ cls, cfg, data: (cfg && cfg.data) || [] }),
    }),
});
vm.runInNewContext(fs.readFileSync('webman/mf_diskwatch.js', 'utf8'), dwSandbox);
assert(dwProto, 'MountFix.Diskwatch definition not captured');

assert.strictEqual(dwProto.formatDwSeconds(45, false), '00:45');
assert.strictEqual(dwProto.formatDwSeconds(300, false), '05:00');
assert.strictEqual(dwProto.formatDwSeconds(65, true), '00:01:05');
assert.strictEqual(dwProto.formatDwSeconds(3600, false), '01:00:00');
assert.strictEqual(dwProto.formatDwSeconds(43200, true), '12:00:00');
assert(dwProto.formatDwKb(0).includes('—'));
assert.strictEqual(dwProto.formatDwKb(512), '512K');
assert.strictEqual(dwProto.formatDwKb(2048), '2.0M');
assert.strictEqual(dwProto.formatDwKb(2097152), '2.0G');

const panelCfg = dwProto.createDiskwatchPanel.call(dwProto);
const durComboCfg = panelCfg.items[0].items[0].items[0];
const durValues = Array.from(durComboCfg.store.data, (d) => d.value);
assert.deepStrictEqual(
    durValues,
    [30, 60, 300, 600, 1200, 1800, 2700, 3600, 7200, 10800, 14400, 21600, 28800, 43200],
    'Duration store must contain exact 30s..12h presets without 5s',
);

const dwUiState = {
    startDisabled: false,
    stopDisabled: true,
    durDisabled: false,
    colDisabled: false,
    progressHtml: '',
    badgeHtml: '',
    summaryHtml: '',
    culprits: [],
    timeline: [],
};
function makeDwPage() {
    return Object.assign({}, dwProto, {
        _dwPollTimer: null,
        _dwPollActive: false,
        updateStatus() {},
        win: {
            isDestroyed: false,
            down: (sel) => {
                if (sel === '#dwDuration') return { getValue: () => 43200, setDisabled: (v) => { dwUiState.durDisabled = v; } };
                if (sel === '#dwCollector') return { getValue: () => 'iotop-static', setDisabled: (v) => { dwUiState.colDisabled = v; } };
                if (sel === '#btnDwStart') return { setDisabled: (v) => { dwUiState.startDisabled = v; } };
                if (sel === '#btnDwStop') return { setDisabled: (v) => { dwUiState.stopDisabled = v; } };
                if (sel === '#dwProgressText') return { update: (h) => { dwUiState.progressHtml = h; } };
                if (sel === '#dwCollectorBadge') return { update: (h) => { dwUiState.badgeHtml = h; } };
                if (sel === '#dwHddSummary') return { update: (h) => { dwUiState.summaryHtml = h; } };
                if (sel === '#dwCulpritsGrid') return { getStore: () => ({ loadData: (d) => { dwUiState.culprits = d; } }) };
                if (sel === '#dwTimelineGrid') return { getStore: () => ({ loadData: (d) => { dwUiState.timeline = d; } }) };
                return null;
            },
        },
    });
}

timeoutCallbacks = [];
const dwPage = makeDwPage();
nextAjaxResponse = {
    success: true,
    result: {
        state: 'running',
        collector: 'iotop-static',
        duration: 43200,
        interval: 10,
        elapsed: 3661,
        hddPower: [{ disk: 'sda', state: 'standby' }],
        hddReadKB: 1024,
        hddWriteKB: 0,
        eventCount: 1,
        culprits: [{ process: 'mc', appName: 'entware', relocationStatus: 'ssd_mounted' }],
        timeline: [{ time: '11:00:00', devices: 'sda(+1024K/+0K)', processes: 'mc' }],
    },
};
dwPage.startDiskwatchCapture();
assert.strictEqual(dwUiState.startDisabled, true, 'Start must be disabled while running');
assert.strictEqual(dwUiState.stopDisabled, false, 'Stop must be enabled while running');
assert(dwUiState.progressHtml.includes('01:01:01 / 12:00:00'), '12h progress must use HH:MM:SS format');
assert.strictEqual(timeoutCallbacks.length, 1, 'Running state must schedule 2s poll');

// Simulate AJAX failure during poll -> must stop polling and re-enable controls
let forceFailure = false;
dwSandbox.AS.ARC.ajax = (opts) => {
    if (forceFailure) opts.failure && opts.failure({});
    else origAjax(opts);
};
forceFailure = true;
timeoutCallbacks[0]();
assert.strictEqual(dwPage._dwPollActive, false, 'Poll failure must stop polling');
assert.strictEqual(dwUiState.startDisabled, false, 'Poll failure must re-enable Start button');
assert.strictEqual(dwUiState.stopDisabled, true, 'Poll failure must disable Stop button');
assert.strictEqual(dwUiState.durDisabled, false, 'Poll failure must re-enable Duration combo');
assert.strictEqual(dwUiState.colDisabled, false, 'Poll failure must re-enable Collector combo');

// 24. Safe Delete Target UI: button gating, confirmation modal variants, and typing <app> unlock
const delBtnStates = {};
let delHint = '';
const makeDelBtn = (id) => ({
    setText() {},
    setDisabled(v) { delBtnStates[id] = !!v; },
    disable() { delBtnStates[id] = true; },
});
p = makePage();
p.updateActionsUI = actionsProto.updateActionsUI;
p.win.down = (sel) => {
    if (sel === '#btnCopyToTarget') return makeDelBtn('copy');
    if (sel === '#btnMount') return makeDelBtn('mount');
    if (sel === '#btnUnmount') return makeDelBtn('unmount');
    if (sel === '#btnSyncBack') return makeDelBtn('sync');
    if (sel === '#btnDeleteTarget') return makeDelBtn('del');
    if (sel === '#actionHint') return { update(h) { delHint = h; } };
    return null;
};

// Stopped, unmounted, existsInTarget=true, NOT configured -> Delete target enabled
p._validatingCount = 0;
p.selectedApp = { get: (k) => (k === 'name' ? 'minidlna' : k === 'existsInTarget') };
p.updateActionsUI();
assert.strictEqual(delBtnStates.del, false, 'Delete target must be enabled for stopped, unmounted, unconfigured app with target copy');

// Configured for boot -> Delete target disabled + hint explains unchecking Boot
p.selectedApp = { get: (k) => (k === 'name' ? 'minidlna' : (k === 'existsInTarget' || k === 'configured')) };
p.updateActionsUI();
assert.strictEqual(delBtnStates.del, true, 'Delete target must be disabled when app is configured for boot');
assert(delHint.includes('Boot') && delHint.includes('Apply'), 'actionHint must instruct unchecking Boot before deleting target');

// Mounted -> Delete target disabled
p.selectedApp = { get: (k) => (k === 'name' ? 'minidlna' : (k === 'existsInTarget' || k === 'mounted')) };
p.updateActionsUI();
assert.strictEqual(delBtnStates.del, true, 'Delete target must be disabled while mounted');

// Running -> Delete target disabled
p.selectedApp = { get: (k) => (k === 'name' ? 'minidlna' : (k === 'existsInTarget' || k === 'enabled')) };
p.updateActionsUI();
assert.strictEqual(delBtnStates.del, true, 'Delete target must be disabled while running');

// In-sync preview opens subWindow with [Delete target, Cancel] locked until exact app name is typed
createdDialogs = [];
sandbox.Ext.ClassManager.isCreated = (cls) => cls === 'AS.ARC.subWindow' || cls === 'AS.ARC.msgWindow';
const makeMockSubWindow = (cls, cfg) => {
    const btnMap = {};
    (cfg.fbar || []).forEach((b) => {
        if (b.itemId) {
            btnMap['#' + b.itemId] = {
                disabled: !!b.disabled,
                setDisabled(v) { this.disabled = !!v; },
            };
        }
    });
    const inst = {
        cls,
        cfg,
        shown: false,
        closed: false,
        show() { this.shown = true; },
        close() { this.closed = true; },
        down(sel) { return btnMap[sel] || null; },
        _btnMap: btnMap,
    };
    createdDialogs.push(inst);
    return inst;
};
const origCreate = sandbox.Ext.create;
sandbox.Ext.create = makeMockSubWindow;

p = makePage();
p.showDeleteTargetDialog('/volume2', 'minidlna', {
    targetPath: '/volume2/AppCentral/minidlna',
    targetSize: '42.0M',
    hasDifferences: false,
    hasHddOnly: false,
    counts: { extraOnSsd: 0, modifiedOnSsd: 0, onlyOnHdd: 0 },
    samples: [],
});
assert.strictEqual(createdDialogs.length, 1);
assert.strictEqual(createdDialogs[0].cfg.layout, 'fit', 'subWindow must use layout: fit for ADM 5.1.5 compatibility');
assert.strictEqual(
    createdDialogs[0].cfg.fbar.map((b) => b.text).join('|'),
    'Delete target|Cancel',
    'In-sync modal must show [Delete target, Cancel]',
);
const inSyncPanel = createdDialogs[0].cfg.items[0];
assert(
    /<input type="checkbox" id="[^"]+"><label for="[^"]+"[^>]*><span[^>]*><\/span><div>/.test(inSyncPanel.html),
    'Modal HTML must use ADM adm3.css sibling input[type="checkbox"] + label > span sprite structure',
);
assert.strictEqual(createdDialogs[0]._btnMap['#btnConfirmDeleteTarget'].disabled, true, 'Delete target must start disabled');
let inSyncChangeHandler = null;
const mockInSyncCb = { checked: false, addEventListener(ev, fn) { if (ev === 'change') inSyncChangeHandler = fn; } };
inSyncPanel.listeners.afterrender({ getEl: () => ({ dom: { querySelector: () => mockInSyncCb } }) });
assert(inSyncChangeHandler, 'afterrender must attach change listener to checkbox');
mockInSyncCb.checked = true;
inSyncChangeHandler();
assert.strictEqual(createdDialogs[0]._btnMap['#btnConfirmDeleteTarget'].disabled, false, 'Checking confirmation must enable Delete target');
mockInSyncCb.checked = false;
inSyncChangeHandler();
assert.strictEqual(createdDialogs[0]._btnMap['#btnConfirmDeleteTarget'].disabled, true, 'Unchecking confirmation must re-disable Delete target');

// Diff preview opens subWindow with [Sync back & Delete target, Delete target only, Cancel]
createdDialogs = [];
p.showDeleteTargetDialog('/volume2', 'minidlna', {
    targetPath: '/volume2/AppCentral/minidlna',
    targetSize: '42.0M',
    hasDifferences: true,
    hasHddOnly: false,
    totalChanges: 2,
    counts: { extraOnSsd: 1, modifiedOnSsd: 1, onlyOnHdd: 0 },
    samples: [{ change: 'extra_on_ssd', path: 'new.db' }],
});
assert.strictEqual(
    createdDialogs[0].cfg.fbar.map((b) => b.text).join('|'),
    'Sync back & Delete target|Delete target only|Cancel',
    'Diff modal must show [Sync back & Delete target, Delete target only, Cancel]',
);
const diffPanel = createdDialogs[0].cfg.items[0];
assert.strictEqual(createdDialogs[0]._btnMap['#btnConfirmSyncAndDelete'].disabled, true);
assert.strictEqual(createdDialogs[0]._btnMap['#btnConfirmDeleteTarget'].disabled, true);
let diffChangeHandler = null;
const mockDiffCb = { checked: false, addEventListener(ev, fn) { if (ev === 'change') diffChangeHandler = fn; } };
diffPanel.listeners.afterrender({ getEl: () => ({ dom: { querySelector: () => mockDiffCb } }) });
mockDiffCb.checked = true;
diffChangeHandler();
assert.strictEqual(createdDialogs[0]._btnMap['#btnConfirmSyncAndDelete'].disabled, false);
assert.strictEqual(createdDialogs[0]._btnMap['#btnConfirmDeleteTarget'].disabled, false);

sandbox.Ext.create = origCreate;

// Test: Two-tier validate() (Tier 1 mode=fast unlocks actions, Tier 2 mode=sizes runs in background; forceRefresh passes refresh=1)
const origAjaxTwoTier = sandbox.AS.ARC.ajax;
const ajaxQueue = [];
sandbox.AS.ARC.ajax = (opts) => {
    ajaxQueue.push(opts);
};

const recData = { name: 'docker-ce', existsInTarget: false, mounted: null, configured: false, selected: false, sourceSize: '0', targetSize: '0' };
const mockRecord = {
    data: recData,
    committed: 0,
    get(k) { return this.data[k]; },
    set(obj) { Object.assign(this.data, obj); },
    commit() { this.committed++; },
};
const mockStore = {
    findRecord(field, val) { return val === 'docker-ce' ? mockRecord : null; },
    add() {},
    data: { items: [mockRecord] },
};
p = makePage();
p.validate = actionsProto.validate;
p.applyValidatedApps = actionsProto.applyValidatedApps;
p.selectedApp = mockRecord;
p.win.down = (sel) => {
    if (sel === 'combo[name=targetVolume]') return { getValue: () => '/volume2' };
    if (sel === '#appGrid') return { getStore: () => mockStore };
    return null;
};

p.validate(null, false, { forceRefresh: true });
assert.strictEqual(ajaxQueue.length, 1, 'Tier 1 must fire immediately');
assert(ajaxQueue[0].url.includes('mode=fast'), 'Tier 1 must request mode=fast');
assert.strictEqual(p._validatingCount, 1, 'Tier 1 increments _validatingCount');

ajaxQueue[0].success({
    success: true,
    mode: 'fast',
    apps: [{ name: 'docker-ce', existsInTarget: true, mounted: null, configured: false, mismatch: null }],
});
assert.strictEqual(p._validatingCount, 0, 'Tier 1 completion unlocks action buttons before Tier 2 finishes');
assert.strictEqual(mockRecord.get('existsInTarget'), true, 'Tier 1 updates record state');
assert.strictEqual(ajaxQueue.length, 2, 'Tier 2 must fire after Tier 1');
assert(ajaxQueue[1].url.includes('mode=sizes') && ajaxQueue[1].url.includes('refresh=1'), 'Tier 2 must pass mode=sizes&refresh=1 on forceRefresh');

ajaxQueue[1].success({
    success: true,
    mode: 'sizes',
    apps: [{ name: 'docker-ce', sourceSize: '120.0M', targetSize: '120.0M' }],
});
assert.strictEqual(mockRecord.get('sourceSize'), '120.0M', 'Tier 2 populates sourceSize');
assert.strictEqual(mockRecord.get('targetSize'), '120.0M', 'Tier 2 populates targetSize');

// Test: Optimistic UI updates in bindMountAction (D.2)
ajaxQueue.length = 0;
p.validateCalls.length = 0;
p.validate = (app, silent, opts) => { p.validateCalls.push({ app, silent, opts }); };
p.bindMountAction('mount', 'Mounting...', 'Mounted');
assert.strictEqual(ajaxQueue.length, 1);
ajaxQueue[0].success({ success: true, bindSource: '/volume2/AppCentral/docker-ce', bindTarget: '/volume1/.@plugins/AppCentral/docker-ce', configUpdated: true });
assert(mockRecord.get('mounted') && mockRecord.get('mounted').target === '/volume1/.@plugins/AppCentral/docker-ce', 'Optimistic mount must set mounted immediately');
assert.strictEqual(mockRecord.get('configured'), true, 'Optimistic mount must set configured=true');
assert.strictEqual(p.validateCalls.length, 1);
assert.strictEqual(p.validateCalls[0].opts.mode, 'fast', 'Post-mount reconciliation should use mode=fast');

// Test: monitorMigrationStatus updates both mask text and persistent #statusInfo with live % and speed
ajaxQueue.length = 0;
timeoutCallbacks.length = 0;
let lastMaskText = '';
const statusUpdates = [];
p = makePage();
p.win.el = {
    mask(m) { lastMaskText = m; },
    unmask() {},
    down(sel) {
        if (sel === '.x-mask-msg-text') return { update(html) { lastMaskText = html; } };
        return null;
    },
};
p.updateStatus = (msg, isErr, persist) => { statusUpdates.push({ msg, isErr, persist }); };
p.monitorMigrationStatus('Copying docker-ce');
assert.strictEqual(timeoutCallbacks.length, 1);
timeoutCallbacks.shift()();
assert.strictEqual(ajaxQueue.length, 1);
ajaxQueue[0].success({
    success: true,
    result: { app: 'docker-ce', state: 'running', progress: 42, lastLine: ' 12,345,678  42%  14.20MB/s  0:00:04' },
});
assert.strictEqual(lastMaskText, 'Copying docker-ce: 42% (14.20MB/s)', 'Mask text must show live % and speed');
assert(
    statusUpdates.some((s) => s.msg === 'Copying docker-ce: 42% (14.20MB/s)' && s.persist === true),
    'Footer #statusInfo must receive persistent live progress updates',
);
p.stopMigrationMonitor();

// Test: loadConfig failure disables #btnApply and shows persistent error; subsequent success re-enables #btnApply
ajaxQueue.length = 0;
statusUpdates.length = 0;
let applyDisabled = false;
const mockBtnApply = { setDisabled(v) { applyDisabled = !!v; } };
p = makePage();
p.win.down = (sel) => (sel === '#btnApply' ? mockBtnApply : null);
p.updateStatus = (msg, isErr, persist) => { statusUpdates.push({ msg, isErr, persist }); };
p.setMfConfig = () => {};
p.validate = () => {};
p.updateActionsUI = () => {};

p.loadConfig();
assert.strictEqual(ajaxQueue.length, 1);
ajaxQueue[0].failure({ success: false, error: 'Entware/jq is not ready yet (NAS may still be booting).' });
assert.strictEqual(applyDisabled, true, 'loadConfig failure must disable #btnApply');
assert(
    statusUpdates.some((s) => s.msg.includes('Entware/jq is not ready') && s.isErr === true && s.persist === true),
    'loadConfig failure must show persistent error message from backend',
);

p.loadConfig();
assert.strictEqual(ajaxQueue.length, 2);
ajaxQueue[1].success({ success: true, config: { targetVolume: '/volume2' }, apps: [], volumes: [] });
assert.strictEqual(applyDisabled, false, 'loadConfig success must re-enable #btnApply');

sandbox.AS.ARC.ajax = origAjaxTwoTier;
EOF
fi

echo "PASS: UI build verification passed."

