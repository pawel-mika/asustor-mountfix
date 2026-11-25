/**
 * MountFix Actions
 */
Ext.define('AS.ARC.apps.MountFix.Actions', {
    maskStack: [],

    // Paths to API (adjust if folder name is different)
    appsApiUrl: AS.ARC.util.getUserAppsPath() + 'MountFix/' + 'apps.cgi',
    configApiUrl: AS.ARC.util.getUserAppsPath() + 'MountFix/' + 'config.cgi',
    validateApiUrl: AS.ARC.util.getUserAppsPath() + 'MountFix/' + 'validate.cgi',
    migrateApiUrl: AS.ARC.util.getUserAppsPath() + 'MountFix/' + 'migrate.cgi',
    mountApiUrl: AS.ARC.util.getUserAppsPath() + 'MountFix/' + 'mount.cgi',

    cgiConfig: {}, // Placeholder for config loaded from CGI

    selectedApp: null, // Currently selected app in the grid

    getSelectedVolume: function () {
        return this.win.down('combo[name=targetVolume]')?.getValue() ?? null;
    },

    // refresh ui elements related to actions based on current state (like selected app)
    updateActionsUI: function () {
        var btnCopyToTarget = this.win.down('#btnCopyToTarget');
        var btnMount = this.win.down('#btnMount');
        var btnUnmount = this.win.down('#btnUnmount');
        var btnSyncBack = this.win.down('#btnSyncBack');
        if (!btnCopyToTarget) return;

        if (this.selectedApp) {
            const mounted = !!this.selectedApp.get('mounted');
            const running = !!this.selectedApp.get('enabled');
            const existsInTarget = !!this.selectedApp.get('existsInTarget');
            btnCopyToTarget.setText('Copy to target: ' + this.selectedApp.get('name'));
            // All actions (Copy, Mount, Unmount, Sync) require the app to be stopped to prevent filesystem conflicts
            btnCopyToTarget.setDisabled(running || mounted);
            btnMount.setDisabled(running || !existsInTarget || mounted);
            btnUnmount.setDisabled(running || !mounted);
            btnSyncBack.setDisabled(running || !existsInTarget || mounted);
        } else {
            btnCopyToTarget.setText('Copy to target');
            btnCopyToTarget.disable();
            btnMount.disable();
            btnUnmount.disable();
            btnSyncBack.disable();
        }
    },

    updateStatus: function (message, isError) {
        var statusCont = this.win.down('#statusInfo');
        var color = isError ? '#cc0000' : '#007dff';
        var icon = isError ? 'alert.png' : 'common-icon_16X16_status_tip_ok.png';
        statusCont.update('<img src="resources/images/icons/common_16x16/' + icon + '" style="vertical-align:middle; margin-right:5px;">' + message);
        statusCont.el.setStyle('color', color);
        statusCont.el.setOpacity(1);

        Ext.defer(function () {
            if (statusCont.el) {
                statusCont.el.fadeOut({ duration: 1000 });
            }
        }, 4000);
    },

    getApps: function () {
        var page = this;

        AS.ARC.ajax({
            url: AS.ARC.util.getApiUrlWithSid(page.appsApiUrl, { act: 'get' }),
            method: 'GET',
            success: function (json) {
                console.log('Apps:', json);
            },
            failure: function () {
                console.error('Failed to load apps');
            },
        });
    },

    loadConfig: function () {
        var page = this;
        var actionMsg = 'Loading configuration...';
        window.qq = this;
        page.maskWindow(actionMsg);

        AS.ARC.ajax({
            url: AS.ARC.util.getApiUrlWithSid(page.configApiUrl, { act: 'get' }),
            method: 'GET',
            success: function (json) {
                console.log('Config loaded:', json);
                page.setMfConfig(json); // Update UI with loaded config
                page.updateActionsUI();
                page.validate();
                page.unmaskWindow(actionMsg);
            },
            failure: function () {
                console.error('Failed to load config');
                page.unmaskWindow(actionMsg);
            },
        });
    },

    saveConfig: function () {
        var page = this;
        var actionMsg = 'Saving configuration...';
        page.maskWindow(actionMsg);

        AS.ARC.ajax({
            url: AS.ARC.util.getApiUrlWithSid(page.configApiUrl, { act: 'set' }),
            params: Ext.encode(page.getMfConfig()),
            success: function (json) {
                page.updateStatus('Settings applied successfully', false);
                page.unmaskWindow(actionMsg);
            },
            failure: function (json) {
                page.updateStatus('Error: ' + ((json && json.error) || 'Unable to save settings'), true);
                page.unmaskWindow(actionMsg);
            },
        });
    },

    validate: function (appName) {
        var page = this;
        var target = page.getSelectedVolume();
        var params = {
            act: 'get',
            target: target,
        };
        if (appName) {
            params.app = appName;
        }
        page.updateStatus('Validating' + (appName ? ' ' + appName : '') + '...', false);

        AS.ARC.ajax({
            url: AS.ARC.util.getApiUrlWithSid(page.validateApiUrl, params),
            method: 'GET',
            success: function (json) {
                if (json.success && json.apps) {
                    var grid = page.win.down('#appGrid');
                    if (grid) {
                        var store = grid.getStore();
                        json.apps.forEach(function (app) {
                            var updateData = Ext.apply({}, app);
                            if (typeof app.configured === 'boolean') {
                                updateData.selected = app.configured;
                            }
                            var record = store.findRecord('name', app.name, 0, false, false, true);
                            if (record) {
                                record.set(updateData);
                            } else {
                                store.add(updateData);
                            }
                        });
                    }
                }
                page.updateActionsUI();
            },
            failure: function () {
                page.updateStatus('Error: Failed to load validation data', true);
            },
        });
    },

    setMfConfig: function (newConfig) {
        var page = this;
        page.cgiConfig = newConfig; // Store config
        var selectedApps = newConfig.config?.selectedApps?.map(({ name }) => name) || [];
        var mappedApps = (newConfig.apps || []).map(({ package, enabled, mounted }) => ({
            name: package,
            selected: selectedApps.includes(package),
            enabled,
            status: 'unknown',
        }));
        var grid = page.win.down('#appGrid');
        if (grid) {
            grid.getStore().loadData(mappedApps);
        }
        if (newConfig.volumes) {
            var combo = page.win.down('combo[name=targetVolume]');
            if (combo) {
                combo.getStore().loadData(newConfig.volumes);
                if (combo.suspendEvents) {
                    combo.suspendEvents();
                }
                combo.setValue(newConfig.config.targetVolume);
                if (combo.resumeEvents) {
                    combo.resumeEvents();
                }
            }
        }
        if (newConfig.version) {
            var verField = page.win.down('#displayVersion');
            if (verField) {
                verField.setValue(newConfig.version);
            }
        }
    },

    getMfConfig: function () {
        var page = this;
        var panel = page.win.down('#mainPanel');
        // Retrieving data from the form
        var values = panel.getValues();
        // 2. Grid (applications)
        var grid = page.win.down('#appGrid');
        values.selectedApps = grid
            .getStore()
            .data.items.map(r => r.data.selected && { name: r.get('name') })
            .filter(Boolean);
        return values;
    },

    promptTargetExists: function (app, target) {
        var page = this;
        if (Ext.ClassManager && Ext.ClassManager.isCreated('AS.ARC.msgWindow')) {
            var confirmDlg = Ext.create('AS.ARC.msgWindow', {
                parentWin: page.win,
                title: 'Target Directory Exists',
                width: 500,
                height: 220,
                iconType: 'warning',
                asItems: [
                    {
                        xtype: 'displayfield',
                        value:
                            '<div style="font-size: 13px; font-weight: bold; margin-bottom: 8px;">' +
                            'Target folder already contains data' +
                            '</div>' +
                            '<div style="font-size: 12px; line-height: 18px;">' +
                            'Target directory for <b>' +
                            Ext.String.htmlEncode(app) +
                            '</b> on volume <b>' +
                            Ext.String.htmlEncode(target) +
                            '</b> already contains data.<br><br>' +
                            'Are you sure you want to continue? Mirror mode (<code>--delete</code>) will overwrite files and remove any extra files on the target volume so it becomes an exact copy of the source.' +
                            '</div>',
                    },
                ],
                fbar: [
                    {
                        text: 'Continue',
                        handler: function () {
                            confirmDlg.close();
                            page.migrateSelectedApp(true);
                        },
                    },
                    {
                        text: 'Cancel',
                        handler: function () {
                            confirmDlg.close();
                        },
                    },
                ],
            });
            confirmDlg.show();
        } else {
            Ext.Msg.confirm(
                'Target Directory Exists',
                'Target directory for ' +
                    Ext.String.htmlEncode(app) +
                    ' on volume ' +
                    Ext.String.htmlEncode(target) +
                    ' already contains data.<br><br>Are you sure you want to continue? Mirror mode (--delete) will overwrite files and remove extra files on the target volume so it becomes an exact copy of the source.',
                function (btn) {
                    if (btn === 'yes') {
                        page.migrateSelectedApp(true);
                    }
                },
            );
        }
    },

    migrateSelectedApp: function (force) {
        var page = this;
        var actionMsg = 'Copying application...';
        var target = page.getSelectedVolume();
        var app = page.selectedApp && (page.selectedApp.get ? page.selectedApp.get('name') : page.selectedApp.data.name);

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
                var res = (json && json.result) || {};
                if (res.target_exists && !force) {
                    page.unmaskWindow(actionMsg);
                    page.promptTargetExists(app, target);
                    return;
                }
                if (json && json.success && (res.success || res.success === undefined)) {
                    page.unmaskWindow(actionMsg);
                    page.updateStatus('Started copying ' + app, false);
                    page.monitorMigrationStatus('Copying ' + app);
                } else {
                    page.unmaskWindow(actionMsg);
                    page.updateStatus('Error: ' + (res.error || (json && json.error) || 'Failed to start copying'), true);
                }
            },
            failure: function (json) {
                var res = (json && json.result) || {};
                if (res.target_exists && !force) {
                    page.unmaskWindow(actionMsg);
                    page.promptTargetExists(app, target);
                    return;
                }
                page.unmaskWindow(actionMsg);
                page.updateStatus('Error: ' + (res.error || (json && json.error) || 'Unable to start copying'), true);
            },
        });
    },

    syncBackSelectedApp: function (callbackOnComplete, skipConfirm) {
        var page = this;
        var target = page.getSelectedVolume();
        var app = page.selectedApp && (page.selectedApp.get ? page.selectedApp.get('name') : page.selectedApp.data.name);

        if (!target || !app) {
            page.updateStatus('Error: Select volume and application first', true);
            return;
        }

        var startSyncBack = function () {
            var actionMsg = 'Syncing back ' + app + '...';
            page.maskWindow(actionMsg);

            AS.ARC.ajax({
                url: AS.ARC.util.getApiUrlWithSid(page.migrateApiUrl, { act: 'sync_back', target: target, app: app }),
                method: 'GET',
                success: function (json) {
                    var res = (json && json.result) || {};
                    if (json && json.success && (res.success || res.success === undefined)) {
                        page.unmaskWindow(actionMsg);
                        page.updateStatus('Started sync-back for ' + app, false);
                        page.monitorMigrationStatus('Sync-back ' + app, callbackOnComplete);
                    } else {
                        page.unmaskWindow(actionMsg);
                        page.updateStatus('Error: ' + (res.error || (json && json.error) || 'Failed to start sync back'), true);
                    }
                },
                failure: function (json) {
                    page.unmaskWindow(actionMsg);
                    page.updateStatus('Error: ' + ((json && json.result && json.result.error) || (json && json.error) || 'Unable to start sync back'), true);
                },
            });
        };

        if (skipConfirm) {
            startSyncBack();
            return;
        }

        if (Ext.ClassManager && Ext.ClassManager.isCreated('AS.ARC.msgWindow')) {
            var confirmDlg = Ext.create('AS.ARC.msgWindow', {
                parentWin: page.win,
                title: 'Sync back: ' + app,
                width: 500,
                height: 220,
                iconType: 'warning',
                asItems: [
                    {
                        xtype: 'displayfield',
                        value:
                            '<div style="font-size: 13px; font-weight: bold; margin-bottom: 8px;">' +
                            'Mirror SSD data back to source volume?' +
                            '</div>' +
                            '<div style="font-size: 12px; line-height: 18px;">' +
                            'Sync-back for <b>' +
                            Ext.String.htmlEncode(app) +
                            '</b> from <b>' +
                            Ext.String.htmlEncode(target) +
                            '</b> runs in mirror mode (<code>--delete</code>).<br><br>' +
                            'The source copy on HDD will be made identical to SSD (files deleted on SSD will also be removed from HDD).' +
                            '</div>',
                    },
                ],
                fbar: [
                    {
                        text: 'Sync back',
                        handler: function () {
                            confirmDlg.close();
                            startSyncBack();
                        },
                    },
                    {
                        text: 'Cancel',
                        handler: function () {
                            confirmDlg.close();
                        },
                    },
                ],
            });
            confirmDlg.show();
        } else {
            Ext.Msg.confirm(
                'Sync back: ' + app,
                'Sync-back for ' +
                    Ext.String.htmlEncode(app) +
                    ' from ' +
                    Ext.String.htmlEncode(target) +
                    ' runs in mirror mode (--delete).<br><br>The HDD copy will be made identical to SSD (files deleted on SSD will also be removed from HDD). Continue?',
                function (btn) {
                    if (btn === 'yes') {
                        startSyncBack();
                    }
                },
            );
        }
    },

    mountSelectedApp: function () {
        var app = this.selectedApp && (this.selectedApp.get ? this.selectedApp.get('name') : this.selectedApp.data.name);
        var label = app ? (' ' + app) : '';
        this.bindMountAction('mount', 'Mounting' + label + '...', 'Mounted' + label + ' successfully');
    },

    unmountSelectedApp: function () {
        var page = this;
        var app = page.selectedApp && (page.selectedApp.get ? page.selectedApp.get('name') : page.selectedApp.data.name);
        if (!app) {
            page.updateStatus('Error: Select an application to unmount', true);
            return;
        }

        var running = !!(page.selectedApp && (page.selectedApp.get ? page.selectedApp.get('enabled') : page.selectedApp.data.enabled));
        if (running) {
            page.updateStatus('Application ' + app + ' is currently running. Stop it in AppCentral before unmounting.', true);
            return;
        }

        var onUnmountWithSyncBack = function () {
            // Unmount first, and only on successful unmount trigger sync-back (skip second confirm)
            page.bindMountAction('unmount', 'Unmounting ' + app + '...', 'Unmounted ' + app + ' successfully', function () {
                page.syncBackSelectedApp(null, true);
            });
        };

        var onUnmountOnly = function () {
            page.bindMountAction('unmount', 'Unmounting ' + app + '...', 'Unmounted ' + app + ' successfully');
        };

        if (Ext.ClassManager && Ext.ClassManager.isCreated('AS.ARC.msgWindow')) {
            var dlg = Ext.create('AS.ARC.msgWindow', {
                parentWin: page.win,
                title: 'Unmount: ' + app,
                width: 500,
                height: 230,
                iconType: 'question',
                asItems: [
                    {
                        xtype: 'displayfield',
                        value: '<div style="font-size: 13px; font-weight: bold; margin-bottom: 8px;">' +
                            'Unmount and Sync-back to source volume?' +
                            '</div>' +
                            '<div style="font-size: 12px; line-height: 18px;">' +
                            'Application <b>' + Ext.String.htmlEncode(app) + '</b> will be unmounted from the target volume.<br><br>' +
                            '<b>Recommendation:</b> Unmount first, then perform Sync-back to mirror latest data from SSD back to HDD (<code>--delete</code>: HDD copy will become identical to SSD).' +
                            '</div>'
                    }
                ],
                fbar: [
                    {
                        text: 'Unmount & Sync-back',
                        handler: function () {
                            dlg.close();
                            onUnmountWithSyncBack();
                        }
                    },
                    {
                        text: 'Unmount only',
                        handler: function () {
                            dlg.close();
                            onUnmountOnly();
                        }
                    },
                    {
                        text: 'Cancel',
                        handler: function () {
                            dlg.close();
                        }
                    }
                ]
            });
            dlg.show();
        } else {
            Ext.Msg.show({
                title: 'Unmount: ' + app,
                msg: 'Application <b>' + Ext.String.htmlEncode(app) + '</b> will be unmounted from the target volume.<br><br>Do you want to perform Sync-back after unmounting? (Mirror mode --delete: HDD copy will become identical to SSD.)',
                buttons: Ext.Msg.YESNOCANCEL,
                buttonText: {
                    yes: 'Unmount & Sync-back',
                    no: 'Unmount only',
                    cancel: 'Cancel',
                },
                fn: function (btn) {
                    if (btn === 'yes') {
                        onUnmountWithSyncBack();
                    } else if (btn === 'no') {
                        onUnmountOnly();
                    }
                }
            });
        }
    },

    bindMountAction: function (act, actionMsg, okMsg, onSuccessCallback) {
        var page = this;
        var target = page.getSelectedVolume();
        var app = page.selectedApp && (page.selectedApp.get ? page.selectedApp.get('name') : page.selectedApp.data.name);

        if (!target || !app) {
            page.updateStatus('Error: Select volume and application first', true);
            return;
        }

        page.maskWindow(actionMsg);
        AS.ARC.ajax({
            url: AS.ARC.util.getApiUrlWithSid(page.mountApiUrl, { act: act, target: target, app: app }),
            method: 'GET',
            success: function (json) {
                page.unmaskWindow(actionMsg);
                if (json && json.success) {
                    page.updateStatus(json.message || okMsg, false);
                    page.updateActionsUI();
                    if (typeof onSuccessCallback === 'function') {
                        onSuccessCallback();
                    } else {
                        page.validate(app);
                    }
                } else {
                    page.updateStatus('Error: ' + ((json && json.error) || 'Operation failed'), true);
                }
            },
            failure: function (json) {
                page.unmaskWindow(actionMsg);
                page.updateStatus('Error: ' + ((json && json.error) || ('Unable to ' + act + ' application')), true);
            },
        });
    },

    monitorMigrationStatus: function (actionLabel, callbackOnComplete) {
        var page = this;
        if (typeof actionLabel === 'function') {
            callbackOnComplete = actionLabel;
            actionLabel = null;
        }

        var app = page.selectedApp && (page.selectedApp.get ? page.selectedApp.get('name') : page.selectedApp.data.name);
        var baseLabel = actionLabel || (app ? ('Operation ' + app) : 'Transfer');
        var initialMask = baseLabel + '...';
        page.maskWindow(initialMask);

        var intervalId = setInterval(function () {
            AS.ARC.ajax({
                url: AS.ARC.util.getApiUrlWithSid(page.migrateApiUrl, { act: 'status' }),
                method: 'GET',
                success: function (json) {
                    var result = (json && json.result) || {};
                    var appName = result.app;
                    var state = result.state;
                    var progress = parseInt(result.progress, 10) || 0;
                    var lastLine = result.lastLine || '';
                    var currentAppName = page.selectedApp && (page.selectedApp.get ? page.selectedApp.get('name') : page.selectedApp.data.name);

                    // Check for explicit failure state or ERROR marker in status file
                    if (state === 'error' || lastLine.indexOf('ERROR') !== -1) {
                        clearInterval(intervalId);
                        page.unmaskAll();
                        page.updateStatus('Error: ' + (lastLine || 'Transfer failed'), true);
                        return;
                    }

                    if (json && json.success) {
                        var statusMsg = (actionLabel || (appName ? ('Transfer ' + appName) : 'Transfer')) + ': ' + progress + '%';
                        page.updateStatus(statusMsg, false);
                        if (page.win && page.win.el) {
                            page.win.el.mask(statusMsg);
                        }

                        var finished = state === 'done' && (!currentAppName || appName === currentAppName);
                        if (finished) {
                            clearInterval(intervalId);
                            page.unmaskAll();
                            page.updateStatus((actionLabel || 'Operation') + ' completed successfully', false);
                            page.validate(appName || app);
                            if (typeof callbackOnComplete === 'function') {
                                callbackOnComplete();
                            }
                        }
                    } else {
                        clearInterval(intervalId);
                        page.unmaskAll();
                        page.updateStatus('Error: ' + ((json && (json.message || json.error)) || 'Transfer failed'), true);
                    }
                },
                failure: function () {
                    clearInterval(intervalId);
                    page.unmaskAll();
                    page.updateStatus('Error: Unable to check transfer status', true);
                },
            });
        }, 500);
    },

    unmaskAll: function () {
        this.maskStack = [];
        if (this.win && this.win.el) {
            this.win.el.unmask();
        }
    },

    maskWindow: function (message) {
        message = message || 'Working...';
        this.maskStack.push(message);
        if (this.win && this.win.el) {
            this.win.el.mask(this.maskStack[this.maskStack.length - 1]);
        }
    },

    unmaskWindow: function (message) {
        if (message) {
            Ext.Array.remove(this.maskStack, message);
        } else {
            this.maskStack.pop();
        }

        if (this.maskStack.length > 0) {
            if (this.win && this.win.el) {
                this.win.el.mask(this.maskStack[this.maskStack.length - 1]);
            }
        } else {
            if (this.win && this.win.el) {
                this.win.el.unmask();
            }
        }
    },

    // Helper function to wrap AS.ARC.ajax into a Promise - unused now, maybe remove later if not needed?
    requestConfig: function (params) {
        var me = this;
        return new Promise(function (resolve, reject) {
            AS.ARC.ajax({
                url: AS.ARC.util.getApiUrlWithSid(me.apiUrl, params),
                method: 'GET',
                success: function (json) {
                    resolve(json);
                },
                failure: function (json) {
                    reject(json);
                },
            });
        });
    },
});


/**
 * MountFix Core
 */
Ext.define('AS.ARC.apps.MountFix.core', {
    extend: 'Ext.util.Observable',
    mixins: ['AS.ARC.apps.MountFix.Actions'],

    constructor: function (config) {
        Ext.apply(this, config);
        this.callParent();
        this.init();
    },

    init: function () {
        var fn = this;

        // Store for the list of applications in the Sources section
        var appStore = Ext.create('Ext.data.Store', {
            fields: ['name', 'selected', 'enabled', 'status', 'sourceSize', 'targetSize', 'mounted', 'existsInTarget', 'configured', 'mismatch'],
            data: [],
        });

        // Main form panel (window base)
        var mainPanel = Ext.create('AS.ARC.formBase', {
            itemId: 'mainPanel',
            cls: 'as-page-panel',
            border: false,
            // Change layout to vbox to manage vertical space
            layout: {
                type: 'vbox',
                align: 'stretch', // Makes items take full width
            },
            bodyPadding: '8 16',
            items: [
                // --- SECTION 1: TARGET ---
                {
                    xtype: 'fieldset',
                    title: 'Target Volume',
                    collapsible: false,
                    layout: 'anchor',
                    items: [
                        {
                            anchor: '100%',
                            xtype: 'combo',
                            fieldLabel: 'Select Volume',
                            name: 'targetVolume',
                            store: {
                                fields: ['volume', 'mountPoint', 'freeSpace', 'totalSpace', 'usedPercent', 'isSSD'],
                                data: [],
                            },
                            queryMode: 'local',
                            displayField: 'volume',
                            valueField: 'volume',
                            editable: false,
                            triggerAction: 'all',
                            tpl: Ext.create(
                                'Ext.XTemplate',
                                '<tpl for=".">',
                                '<div class="x-boundlist-item {[!values.isSSD ? "x-item-disabled" : ""]}">',
                                '{volume} ({mountPoint}) - {freeSpace} of {totalSpace} free, ({usedPercent} used) ',
                                '[',
                                '<tpl if="isSSD">SSD</tpl>',
                                '<tpl if="!isSSD">HDD</tpl>',
                                ']',
                                '</div>',
                                '</tpl>',
                            ),
                            listeners: {
                                beforeselect: function (combo, record) {
                                    return record.get('isSSD');
                                },
                                change: function (combo, newValue) {
                                    fn.validate();
                                },
                            },
                        },
                    ],
                },

                // --- SECTION 2: SOURCES (Grid with applications) ---
                {
                    xtype: 'fieldset',
                    title: 'Sources & Applications',
                    flex: 1,
                    layout: 'fit',
                    margin: '8 0',
                    items: [
                        {
                            xtype: 'grid',
                            itemId: 'appGrid',
                            store: appStore,
                            border: true,
                            columnLines: true,
                            scrollable: true,
                            padding: '0 0 30 0',
                            // Running apps stay selectable (need select to Unmount).
                            // x-item-disabled blocked clicks — do not use it on rows.
                            viewConfig: {
                                getRowClass: function (record) {
                                    return record.get('enabled') ? 'mf-app-running' : '';
                                },
                            },
                            selModel: {
                                allowDeselect: true,
                                listeners: {
                                    selectionchange: function (sm, selected) {
                                        fn.selectedApp = selected.length > 0 ? selected[0] : null;
                                        fn.updateActionsUI();
                                    },
                                },
                            },
                            columns: [
                                {
                                    xtype: 'checkcolumn',
                                    text: 'Boot',
                                    dataIndex: 'selected',
                                    width: 55,
                                    resizable: false,
                                    processEvent: function () {
                                        return false;
                                    },
                                },
                                {
                                    xtype: 'checkcolumn',
                                    text: 'Enabled',
                                    dataIndex: 'enabled',
                                    width: 60,
                                    resizable: false,
                                    processEvent: function () {
                                        return false;
                                    },
                                    renderer: function (value) {
                                        var color = value ? 'green' : 'gray';
                                        var text = value ? 'Running' : 'Stopped';
                                        return '<span style="color:' + color + '; font-weight:light; font-size:9px;">● ' + text + '</span>';
                                    },
                                },
                                {
                                    text: 'Application Name',
                                    dataIndex: 'name',
                                    flex: 1,
                                    menuDisabled: true,
                                },
                                {
                                    text: 'Current Status',
                                    dataIndex: 'status',
                                    width: 145,
                                    renderer: function (v, m, row) {
                                        var data = row.data;
                                        if (data.mismatch === 'mounted_not_configured') {
                                            return '<span style="color:#d97706;" title="Mounted now, will not mount after reboot">Mounted (not in boot)</span>';
                                        }
                                        if (data.mismatch === 'configured_not_mounted') {
                                            return '<span style="color:#d97706;" title="Configured for boot, but not currently mounted">Not mounted (in boot)</span>';
                                        }
                                        var val = data.mounted ? 'Mounted' : data.enabled ? 'Not ready' : 'Ready';
                                        var color = val === 'Ready' ? 'green' : 'gray';
                                        return '<span style="color:' + color + ';">' + val + '</span>';
                                    },
                                },
                                {
                                    text: 'Source Size',
                                    dataIndex: 'sourceSize',
                                    width: 80,
                                    menuDisabled: true,
                                },
                                {
                                    text: 'Target Size',
                                    dataIndex: 'targetSize',
                                    width: 80,
                                    menuDisabled: true,
                                },
                                {
                                    text: 'Mounted on',
                                    dataIndex: 'mounted',
                                    flex: 1,
                                    menuDisabled: true,
                                    renderer: val => val && val.target,
                                },
                            ],
                        },
                    ],
                },

                // --- SECTION 3: MISC ---
                {
                    xtype: 'fieldset',
                    title: 'Options',
                    items: [
                        {
                            xtype: 'fieldcontainer',
                            layout: 'hbox',
                            defaultType: 'button',
                            items: [
                                {
                                    xtype: 'button',
                                    text: 'Copy to target',
                                    itemId: 'btnCopyToTarget',
                                    handler: function () {
                                        fn.migrateSelectedApp();
                                        console.log('copy to target');
                                    },
                                },
                                {
                                    xtype: 'button',
                                    text: 'Mount',
                                    itemId: 'btnMount',
                                    handler: function () {
                                        fn.mountSelectedApp();
                                    },
                                },
                                {
                                    xtype: 'button',
                                    text: 'Unmount',
                                    itemId: 'btnUnmount',
                                    handler: function () {
                                        fn.unmountSelectedApp();
                                    },
                                },
                                {
                                    xtype: 'button',
                                    text: 'Sync back',
                                    itemId: 'btnSyncBack',
                                    handler: function () {
                                        fn.syncBackSelectedApp();
                                    },
                                },
                            ],
                        },
                        {
                            xtype: 'displayfield',
                            itemId: 'displayVersion',
                            fieldLabel: 'Version',
                            value: '0.0.0.107',
                        },
                    ],
                },
            ],

            // --- FOOTER ---
            fbar: [
                {
                    xtype: 'container',
                    itemId: 'statusInfo',
                    html: '',
                    style: 'color: #333; font-size: 12px;',
                    margin: '0 16 0 16',
                },
                { xtype: 'tbfill' }, // Filler moves buttons to the right
                {
                    xtype: 'button',
                    text: 'Apply',
                    itemId: 'btnApply',
                    width: 85,
                    handler: function () {
                        fn.saveConfig();
                    },
                },
                {
                    xtype: 'button',
                    text: 'Cancel',
                    width: 85,
                    handler: function () {
                        fn.win.close();
                    },
                },
            ],
        });

        // Creating window through ADM desktop
        this.win = this.desktop.createWindow({
            app: fn.app,
            id: fn.id,
            title: 'MountFix',
            width: 640,
            height: 640,
            layout: 'fit',
            taskIcon: '..apps/MountFix/images/icon-app-task.png',
            items: [mainPanel],
            listeners: {
                afterrender: function (win) {
                    // Initialization of ADM scrollbar (PerfectScrollbar)
                    if (window.Ps) {
                        Ps.initialize(win.body.dom);
                    }
                    fn.loadConfig(); // Load initial config
                    fn.getApps(); // Load list of apps
                },
            },
        });
    },
});


/**
 * MountFix Main Class - app launcher
 */
Ext.define('AS.ARC.apps.MountFix.main', {
    extend: 'AS.ARC._appBase',

    appTag: 'MountFix',
    title: 'MountFix',
    appMaxNum: 1,
    appOpenNum: 0,
    appIsReady: true,
    appWins: [],

    createWindow: function () {
        var desktop = this.core.getDesktop(),
            app = this;

        if (this.appOpenNum === this.appMaxNum || !this.appIsReady) {
            if (this.appWins[0]) this.appWins[0].show();
            return;
        }

        this.appIsReady = false;

        var mountFixCore = new AS.ARC.apps.MountFix.core({
            app: this,
            desktop: desktop,
            id: 'app-MountFix-win',
        });

        mountFixCore.win.on('render', function () {
            app.appOpenNum++;
            app.appIsReady = true;
        });

        mountFixCore.win.on('beforeclose', function () {
            app.appOpenNum--;
            app.appIsReady = true;
            app.appWins = [];
        });

        mountFixCore.win.show();
        this.appWins.push(mountFixCore.win);
    },
});


