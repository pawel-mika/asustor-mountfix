/**
 * MountFix Actions
 */
Ext.define('AS.ARC.apps.MountFix.Actions', {
    // Paths to API (adjust if folder name is different)
    configApiUrl: AS.ARC.util.getUserAppsPath() + 'MountFix/' + 'config.cgi',
    validateApiUrl: AS.ARC.util.getUserAppsPath() + 'MountFix/' + 'validate.cgi',
    migrateApiUrl: AS.ARC.util.getUserAppsPath() + 'MountFix/' + 'migrate.cgi',
    mountApiUrl: AS.ARC.util.getUserAppsPath() + 'MountFix/' + 'mount.cgi',
    helpDocUrl: 'https://github.com/pawel-mika/asustor-mountfix#readme',

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
        var btnDeleteTarget = this.win.down('#btnDeleteTarget');
        var actionHint = this.win.down('#actionHint');
        if (!btnCopyToTarget) return;

        const validating = (this._validatingCount || 0) > 0;
        if (this.selectedApp) {
            const mounted = !!this.selectedApp.get('mounted');
            const running = !!this.selectedApp.get('enabled');
            const existsInTarget = !!this.selectedApp.get('existsInTarget');
            const configured = !!(this.selectedApp.get('configured') || this.selectedApp.get('selected'));
            const appName = this.selectedApp.get('name');
            btnCopyToTarget.setText('Copy to target: ' + appName);
            // All actions (Copy, Mount, Unmount, Sync, Delete) require validation to finish and the app to be stopped
            btnCopyToTarget.setDisabled(validating || running || mounted);
            btnMount.setDisabled(validating || running || !existsInTarget || mounted);
            btnUnmount.setDisabled(validating || running || !mounted);
            btnSyncBack.setDisabled(validating || running || !existsInTarget || mounted);
            if (btnDeleteTarget) {
                btnDeleteTarget.setDisabled(validating || running || mounted || !existsInTarget || configured);
            }
            if (actionHint) {
                if (validating) {
                    actionHint.update('Validating configuration... actions are temporarily disabled.');
                } else if (running) {
                    actionHint.update(
                        'Stop <b>' +
                            Ext.String.htmlEncode(appName) +
                            '</b> in AppCentral first to copy, mount, unmount, sync back, or delete target.',
                    );
                } else if (!mounted && existsInTarget && configured) {
                    actionHint.update(
                        'Uncheck <b>Boot</b> and click <b>Apply</b> before deleting the target copy of <b>' +
                            Ext.String.htmlEncode(appName) +
                            '</b>.',
                    );
                } else {
                    actionHint.update('&nbsp;');
                }
            }
        } else {
            btnCopyToTarget.setText('Copy to target');
            btnCopyToTarget.disable();
            btnMount.disable();
            btnUnmount.disable();
            btnSyncBack.disable();
            if (btnDeleteTarget) {
                btnDeleteTarget.disable();
            }
            if (actionHint) {
                actionHint.update('&nbsp;');
            }
        }
    },

    updateStatus: function (message, isError, persist) {
        var statusCont = this.win.down('#statusInfo');
        if (!statusCont) return;

        if (this._statusFadeTimer) {
            clearTimeout(this._statusFadeTimer);
            this._statusFadeTimer = null;
        }

        if (!message) {
            statusCont.update('');
            return;
        }

        var color = isError ? '#cc0000' : '#007dff';
        var icon = isError ? 'alert.png' : 'common-icon_16X16_status_tip_ok.png';
        statusCont.update(
            '<span style="display:inline-flex; align-items:center; gap:5px; vertical-align:top;">' +
                '<img src="resources/images/icons/common_16x16/' + icon + '" style="width:16px; height:16px; flex-shrink:0;">' +
                '<span>' + message + '</span>' +
            '</span>',
        );
        if (statusCont.el) {
            statusCont.el.setStyle('color', color);
            statusCont.el.setOpacity(1);
        }

        if (!persist) {
            var page = this;
            this._statusFadeTimer = setTimeout(function () {
                page._statusFadeTimer = null;
                if (statusCont.el) {
                    statusCont.el.fadeOut({ duration: 1000 });
                }
            }, 4000);
        }
    },

    loadConfig: function () {
        var page = this;
        var actionMsg = 'Loading configuration...';
        page.maskWindow(actionMsg);

        AS.ARC.ajax({
            url: AS.ARC.util.getApiUrlWithSid(page.configApiUrl, { act: 'get' }),
            method: 'GET',
            enableFailureReturn: true,
            success: function (json) {
                page.setMfConfig(json); // Update UI with loaded config
                page.updateActionsUI();
                page.validate();
                page.unmaskWindow(actionMsg);
            },
            failure: function () {
                page.updateStatus('Error: Failed to load configuration', true);
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
            method: 'POST',
            enableFailureReturn: true,
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

    validate: function (appName, silent) {
        var page = this;
        var target = page.getSelectedVolume();
        var params = {
            act: 'get',
            target: target,
        };
        if (appName) {
            params.app = appName;
        }
        if (!silent) {
            page.updateStatus('Validating' + (appName ? ' ' + appName : '') + '...', false, true);
        }

        page._validatingCount = (page._validatingCount || 0) + 1;
        page.updateActionsUI();

        AS.ARC.ajax({
            url: AS.ARC.util.getApiUrlWithSid(page.validateApiUrl, params),
            method: 'GET',
            enableFailureReturn: true,
            success: function (json) {
                page._validatingCount = Math.max(0, (page._validatingCount || 1) - 1);
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
                                if (record.commit) {
                                    record.commit();
                                }
                            } else {
                                store.add(updateData);
                            }
                        });
                    }
                }
                page.updateActionsUI();
                if (!silent) {
                    page.updateStatus('', false);
                }
            },
            failure: function () {
                page._validatingCount = Math.max(0, (page._validatingCount || 1) - 1);
                page.updateActionsUI();
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
            if (verField && verField.update) {
                verField.update('v' + Ext.String.htmlEncode(newConfig.version));
            }
        }
        var sysctlChk = page.win.down('#chkSysctlTuning');
        if (sysctlChk && sysctlChk.setValue) {
            sysctlChk.setValue(!!(newConfig.config && newConfig.config.enableSysctlTuning));
        }
    },

    getMfConfig: function () {
        var page = this;
        var panel = page.win.down('#mainPanel');
        // Retrieving data from the form
        var values = panel.getValues();
        var sysctlChk = page.win.down('#chkSysctlTuning');
        values.enableSysctlTuning = !!(sysctlChk && sysctlChk.getValue && sysctlChk.getValue());
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
                width: 620,
                height: 280,
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

    confirmEntwareAction: function (actionLabel, onConfirm) {
        var page = this;
        var bodyHtml =
            '<div style="font-size: 13px; font-weight: bold; margin-bottom: 8px;">' +
            'Entware is a MountFix runtime dependency' +
            '</div>' +
            '<div style="font-size: 12px; line-height: 18px;">' +
            '<b>entware</b> provides tools (<code>jq</code>, <code>rsync</code>, <code>bash</code>) used by MountFix and starts after <code>S02MountFix</code>.<br><br>' +
            'Are you sure you want to ' +
            Ext.String.htmlEncode(actionLabel) +
            ' <b>entware</b>?' +
            '</div>';

        if (Ext.ClassManager && Ext.ClassManager.isCreated('AS.ARC.msgWindow')) {
            var dlg = Ext.create('AS.ARC.msgWindow', {
                parentWin: page.win,
                title: 'Warning: Relocating Entware',
                width: 620,
                height: 270,
                iconType: 'warning',
                asItems: [{ xtype: 'displayfield', value: bodyHtml }],
                fbar: [
                    {
                        text: 'Continue',
                        handler: function () {
                            dlg.close();
                            onConfirm();
                        },
                    },
                    {
                        text: 'Cancel',
                        handler: function () {
                            dlg.close();
                        },
                    },
                ],
            });
            dlg.show();
        } else {
            Ext.Msg.confirm(
                'Warning: Relocating Entware',
                'entware provides tools (jq, rsync, bash) used by MountFix. Are you sure you want to ' +
                    Ext.String.htmlEncode(actionLabel) +
                    ' entware?',
                function (btn) {
                    if (btn === 'yes') {
                        onConfirm();
                    }
                },
            );
        }
    },

    migrateSelectedApp: function (force, skipEntwareWarn) {
        var page = this;
        var actionMsg = 'Copying application...';
        var target = page.getSelectedVolume();
        var app = page.selectedApp && (page.selectedApp.get ? page.selectedApp.get('name') : page.selectedApp.data.name);

        if (!target || !app) {
            page.updateStatus('Error: Select volume and application first', true);
            return;
        }

        if (app === 'entware' && !force && !skipEntwareWarn) {
            page.confirmEntwareAction('copy to target', function () {
                page.migrateSelectedApp(false, true);
            });
            return;
        }

        var existsInTarget = !!(page.selectedApp && (page.selectedApp.get ? page.selectedApp.get('existsInTarget') : page.selectedApp.data.existsInTarget));
        if (!force && existsInTarget) {
            page.promptTargetExists(app, target);
            return;
        }

        var params = { act: 'migrate', target: target, app: app };
        if (force) {
            params.force = '1';
        }

        page.maskWindow(actionMsg);
        AS.ARC.ajax({
            url: AS.ARC.util.getApiUrlWithSid(page.migrateApiUrl, params),
            method: 'POST',
            enableFailureReturn: true,
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

    syncBackSelectedApp: function (callbackOnComplete, skipConfirm, overrideTarget, overrideApp) {
        var page = this;
        var target = overrideTarget || page.getSelectedVolume();
        var app = overrideApp || (page.selectedApp && (page.selectedApp.get ? page.selectedApp.get('name') : page.selectedApp.data.name));

        if (!target || !app) {
            page.updateStatus('Error: Select volume and application first', true);
            return;
        }

        var startSyncBack = function () {
            var actionMsg = 'Syncing back ' + app + '...';
            page.maskWindow(actionMsg);

            AS.ARC.ajax({
                url: AS.ARC.util.getApiUrlWithSid(page.migrateApiUrl, { act: 'sync_back', target: target, app: app }),
                method: 'POST',
                enableFailureReturn: true,
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
                width: 620,
                height: 280,
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

    mountSelectedApp: function (skipEntwareWarn) {
        var page = this;
        var app = page.selectedApp && (page.selectedApp.get ? page.selectedApp.get('name') : page.selectedApp.data.name);
        if (app === 'entware' && !skipEntwareWarn) {
            page.confirmEntwareAction('mount', function () {
                page.mountSelectedApp(true);
            });
            return;
        }
        var label = app ? (' ' + app) : '';
        page.bindMountAction('mount', 'Mounting' + label + '...', 'Mounted' + label + ' successfully');
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
                width: 620,
                height: 290,
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
            method: 'POST',
            enableFailureReturn: true,
            success: function (json) {
                page.unmaskWindow(actionMsg);
                if (json && json.success) {
                    page.updateStatus(json.message || okMsg, false);
                    page.updateActionsUI();
                    if (typeof onSuccessCallback === 'function') {
                        onSuccessCallback();
                    } else {
                        page.validate(app, true);
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

    stopMigrationMonitor: function () {
        this._pollActive = false;
        if (this._pollTimer) {
            clearTimeout(this._pollTimer);
            this._pollTimer = null;
        }
    },

    monitorMigrationStatus: function (actionLabel, callbackOnComplete) {
        var page = this;
        if (typeof actionLabel === 'function') {
            callbackOnComplete = actionLabel;
            actionLabel = null;
        }

        page.stopMigrationMonitor();

        var app = page.selectedApp && (page.selectedApp.get ? page.selectedApp.get('name') : page.selectedApp.data.name);
        var baseLabel = actionLabel || (app ? ('Operation ' + app) : 'Transfer');
        var initialMask = baseLabel + '...';
        page.maskWindow(initialMask);
        page._pollActive = true;

        var poll = function () {
            if (!page._pollActive) {
                return;
            }
            page._pollTimer = null;
            AS.ARC.ajax({
                url: AS.ARC.util.getApiUrlWithSid(page.migrateApiUrl, { act: 'status' }),
                method: 'GET',
                enableFailureReturn: true,
                success: function (json) {
                    if (!page._pollActive) {
                        return;
                    }
                    var result = (json && json.result) || {};
                    var appName = result.app;
                    var state = result.state;
                    var progress = parseInt(result.progress, 10) || 0;
                    var lastLine = result.lastLine || '';
                    var currentAppName = page.selectedApp && (page.selectedApp.get ? page.selectedApp.get('name') : page.selectedApp.data.name);

                    // Check for explicit failure state or ERROR marker in status file
                    if (state === 'error' || lastLine.indexOf('ERROR') !== -1) {
                        page.stopMigrationMonitor();
                        page.unmaskAll();
                        page.updateStatus('Error: ' + (lastLine || 'Transfer failed'), true);
                        return;
                    }

                    if (json && json.success) {
                        var statusMsg = (actionLabel || (appName ? ('Transfer ' + appName) : 'Transfer')) + ': ' + progress + '%';
                        if (page.win && !page.win.isDestroyed && page.win.el) {
                            page.win.el.mask(statusMsg);
                        }

                        var finished = state === 'done' && (!currentAppName || appName === currentAppName);
                        if (finished) {
                            page.stopMigrationMonitor();
                            page.unmaskAll();
                            page.updateStatus((actionLabel || 'Operation') + ' completed successfully', false);
                            page.validate(appName || app, true);
                            if (typeof callbackOnComplete === 'function') {
                                callbackOnComplete();
                            }
                            return;
                        }
                        page._pollTimer = setTimeout(poll, 500);
                    } else {
                        page.stopMigrationMonitor();
                        page.unmaskAll();
                        page.updateStatus('Error: ' + ((json && (json.message || json.error)) || 'Transfer failed'), true);
                    }
                },
                failure: function () {
                    if (!page._pollActive) {
                        return;
                    }
                    page.stopMigrationMonitor();
                    page.unmaskAll();
                    page.updateStatus('Error: Unable to check transfer status', true);
                },
            });
        };

        page._pollTimer = setTimeout(poll, 500);
    },

    buildDeleteTargetSummaryHtml: function (target, app, preview, chkId) {
        var enc = Ext.String.htmlEncode;
        var p = preview || {};
        var counts = p.counts || {};
        var extra = counts.extraOnSsd || 0;
        var modified = counts.modifiedOnSsd || 0;
        var hddOnly = counts.onlyOnHdd || 0;
        var total = p.totalChanges || (extra + modified + hddOnly);
        var samples = p.samples || [];
        var targetPath = p.targetPath || (target + '/AppCentral/' + app);
        var targetSize = p.targetSize && p.targetSize !== '0' ? p.targetSize : '0';
        var hasDiff = !!(p.hasDifferences || p.hasHddOnly);

        var html =
            '<div style="font-size: 12px; line-height: 18px;">' +
            '<div style="font-size: 13px; font-weight: bold; margin-bottom: 6px;">' +
            'Delete SSD copy of ' + enc(app) + '?' +
            '</div>' +
            '<div style="margin-bottom: 10px;">' +
            'Target path: <code>' + enc(targetPath) + '</code> &nbsp;|&nbsp; Reclaimable space: <b>' + enc(targetSize) + '</b>' +
            '</div>';

        if (hasDiff) {
            html +=
                '<div style="background:#fef3c7; border:1px solid #f59e0b; border-radius:4px; padding:8px 10px; margin-bottom:10px; color:#78350f;">' +
                '<b>Differences detected between SSD target and /volume1 copy:</b><br>' +
                '&bull; Extra on SSD (not on /volume1): <b>' + extra + '</b><br>' +
                '&bull; Modified on SSD vs /volume1: <b>' + modified + '</b><br>' +
                '&bull; Only on /volume1 (removed on SSD): <b>' + hddOnly + '</b>';

            if (samples.length > 0) {
                var lines = samples.map(function (item) {
                    var prefix = item.change === 'extra_on_ssd' ? '+ ' : item.change === 'only_on_hdd' ? '- ' : '~ ';
                    return prefix + enc(item.path || '');
                });
                if (total > samples.length) {
                    lines.push('... and ' + (total - samples.length) + ' more');
                }
                html +=
                    '<div style="margin-top:6px; max-height:110px; overflow:auto; background:#fffbeb; border:1px solid #fde68a; padding:6px 8px; font-family:monospace; font-size:11px; white-space:pre;">' +
                    lines.join('\n') +
                    '</div>';
            }
            html += '</div>';
        } else {
            html +=
                '<div style="background:#dcfce7; border:1px solid #16a34a; border-radius:4px; padding:8px 10px; margin-bottom:10px; color:#14532d;">' +
                '<b>In sync with /volume1:</b> No newer or extra files were detected on the target SSD.' +
                '</div>';
        }

        html +=
            '<div style="color:#991b1b; margin-top:4px;">' +
            '<b>Warning:</b> Deletion is permanent and cannot be undone.' +
            '</div>';

        if (chkId) {
            // ADM adm3.css hides raw input[type="checkbox"] (display:none) and draws its themed 16x16 sprite on `input[type="checkbox"] + label span`
            html +=
                '<div style="margin-top:12px; padding:8px 10px; background:#f9fafb; border:1px solid #d1d5db; border-radius:4px;">' +
                '<input type="checkbox" id="' + enc(chkId) + '">' +
                '<label for="' + enc(chkId) + '" style="display:flex; align-items:center; gap:8px; cursor:pointer; user-select:none; color:#111827; line-height:18px;">' +
                '<span style="flex-shrink:0;"></span>' +
                '<div>I understand that deleting <b>' + enc(targetPath) + '</b> is permanent and cannot be undone.</div>' +
                '</label>' +
                '</div>';
        }

        html += '</div>';
        return html;
    },

    showDeleteTargetDialog: function (target, app, preview) {
        var page = this;
        var hasDiff = !!(preview && (preview.hasDifferences || preview.hasHddOnly));
        var targetPath = (preview && preview.targetPath) || (target + '/AppCentral/' + app);
        var chkId = (Ext.id && Ext.id(null, 'mf-del-chk-')) || ('mf-del-chk-' + Date.now());
        var summaryHtml = page.buildDeleteTargetSummaryHtml(target, app, preview, chkId);

        if (Ext.ClassManager && Ext.ClassManager.isCreated('AS.ARC.subWindow')) {
            var dlg = null;
            var setDeleteButtonsEnabled = function (enabled) {
                if (!dlg) return;
                var bSync = dlg.down('#btnConfirmSyncAndDelete');
                var bDel = dlg.down('#btnConfirmDeleteTarget');
                if (bSync) bSync.setDisabled(!enabled);
                if (bDel) bDel.setDisabled(!enabled);
            };

            var fbar = [];
            if (hasDiff) {
                fbar.push({
                    text: 'Sync back & Delete target',
                    itemId: 'btnConfirmSyncAndDelete',
                    disabled: true,
                    handler: function () {
                        dlg.close();
                        page.syncBackSelectedApp(
                            function () {
                                page.executeDeleteTarget(target, app, app);
                            },
                            true,
                            target,
                            app,
                        );
                    },
                });
                fbar.push({
                    text: 'Delete target only',
                    itemId: 'btnConfirmDeleteTarget',
                    disabled: true,
                    handler: function () {
                        dlg.close();
                        page.executeDeleteTarget(target, app, app);
                    },
                });
            } else {
                fbar.push({
                    text: 'Delete target',
                    itemId: 'btnConfirmDeleteTarget',
                    disabled: true,
                    handler: function () {
                        dlg.close();
                        page.executeDeleteTarget(target, app, app);
                    },
                });
            }
            fbar.push({
                text: 'Cancel',
                handler: function () {
                    dlg.close();
                },
            });

            dlg = Ext.create('AS.ARC.subWindow', {
                parentWin: page.win,
                title: 'Delete Target Copy: ' + app,
                width: 640,
                height: hasDiff ? 470 : 340,
                layout: 'fit',
                modal: true,
                items: [
                    {
                        xtype: 'panel',
                        border: false,
                        autoScroll: true,
                        bodyPadding: '12 16',
                        html: summaryHtml,
                        listeners: {
                            afterrender: function (panel) {
                                var dom = panel.getEl && panel.getEl().dom;
                                var cb = (dom && dom.querySelector('#' + chkId)) || (typeof document !== 'undefined' && document.getElementById(chkId));
                                if (cb) {
                                    cb.addEventListener('change', function () {
                                        setDeleteButtonsEnabled(!!cb.checked);
                                    });
                                }
                            },
                        },
                    },
                ],
                fbar: fbar,
            });
            dlg.show();
        } else {
            Ext.Msg.confirm(
                'Delete Target Copy: ' + app,
                'Permanently delete ' + Ext.String.htmlEncode(targetPath) + '? This action cannot be undone.',
                function (btn) {
                    if (btn === 'yes') {
                        page.executeDeleteTarget(target, app, app);
                    }
                },
            );
        }
    },

    deleteSelectedAppTarget: function () {
        var page = this;
        var target = page.getSelectedVolume();
        var app = page.selectedApp && (page.selectedApp.get ? page.selectedApp.get('name') : page.selectedApp.data.name);

        if (!target || !app) {
            page.updateStatus('Error: Select volume and application first', true);
            return;
        }

        var actionMsg = 'Checking target copy for ' + app + '...';
        page.maskWindow(actionMsg);

        AS.ARC.ajax({
            url: AS.ARC.util.getApiUrlWithSid(page.migrateApiUrl, { act: 'delete_preview', target: target, app: app }),
            method: 'GET',
            enableFailureReturn: true,
            success: function (json) {
                page.unmaskWindow(actionMsg);
                var res = (json && json.result) || {};
                if (json && json.success && res.success !== false) {
                    page.showDeleteTargetDialog(target, app, res);
                } else {
                    page.updateStatus('Error: ' + (res.error || (json && json.error) || 'Delete preview failed'), true);
                }
            },
            failure: function (json) {
                page.unmaskWindow(actionMsg);
                var res = (json && json.result) || {};
                page.updateStatus('Error: ' + (res.error || (json && json.error) || 'Unable to inspect target copy'), true);
            },
        });
    },

    executeDeleteTarget: function (target, app, confirmName) {
        var page = this;
        var actionMsg = 'Deleting target copy of ' + app + '...';
        page.maskWindow(actionMsg);

        AS.ARC.ajax({
            url: AS.ARC.util.getApiUrlWithSid(page.migrateApiUrl, {
                act: 'delete_target',
                target: target,
                app: app,
                confirm: confirmName,
            }),
            method: 'POST',
            enableFailureReturn: true,
            success: function (json) {
                page.unmaskWindow(actionMsg);
                var res = (json && json.result) || {};
                if (json && json.success && res.success !== false) {
                    if (res.volumes && res.volumes.length > 0) {
                        var combo = page.win.down('combo[name=targetVolume]');
                        if (combo && combo.getStore) {
                            var curVal = combo.getValue ? combo.getValue() : target;
                            if (combo.suspendEvents) combo.suspendEvents();
                            combo.getStore().loadData(res.volumes);
                            if (combo.setValue) combo.setValue(curVal);
                            if (combo.resumeEvents) combo.resumeEvents();
                        }
                    }
                    page.updateStatus(res.message || ('Deleted target copy of ' + app), false);
                    page.validate(app, true);
                } else {
                    page.updateStatus('Error: ' + (res.error || (json && json.error) || 'Failed to delete target copy'), true);
                }
            },
            failure: function (json) {
                page.unmaskWindow(actionMsg);
                var res = (json && json.result) || {};
                page.updateStatus('Error: ' + (res.error || (json && json.error) || 'Unable to delete target copy'), true);
            },
        });
    },

    showHelpDialog: function () {
        var page = this;
        var docUrl = page.helpDocUrl || 'https://github.com/pawel-mika/asustor-mountfix#readme';
        var bodyHtml =
            '<div style="font-size: 12px; line-height: 18px;">' +
            '<b>Relocate an app (HDD &rarr; SSD):</b><br>' +
            '1. Stop the app in AppCentral &rarr; 2. <b>Copy to target</b> &rarr; 3. <b>Mount</b> &rarr; 4. Start the app.<br><br>' +
            '<b>Move back to HDD (SSD &rarr; HDD):</b><br>' +
            '1. Stop the app in AppCentral &rarr; 2. <b>Unmount &amp; Sync-back</b> &rarr; 3. Start the app &rarr; 4. (Optional) <b>Delete target</b> to reclaim SSD space.<br><br>' +
            '<b>Important safety rules:</b><br>' +
            '&bull; Always stop an application before copying, mounting, unmounting, syncing back, or deleting target data.<br>' +
            '&bull; <b>Sync back</b> and overwriting an existing target use mirror mode (<code>--delete</code>).<br>' +
            '&bull; <b>Delete target</b> previews SSD vs. HDD differences first and requires explicit confirmation.<br>' +
            '&bull; Unmount all apps before uninstalling MountFix (uninstall is blocked while mounts are active).<br>' +
            '&bull; Kernel <code>sysctl</code> tuning is optional (off by default) and applies on boot only.<br><br>' +
            '<a href="' + docUrl + '" target="_blank" rel="noopener noreferrer" style="color: #007dff; text-decoration: underline;">' +
            'Open full documentation on GitHub &rarr;</a>' +
            '</div>';

        if (Ext.ClassManager && Ext.ClassManager.isCreated('AS.ARC.subWindow')) {
            var subDlg = Ext.create('AS.ARC.subWindow', {
                parentWin: page.win,
                title: 'MountFix Quick Guide',
                width: 640,
                height: 360,
                layout: 'fit',
                modal: true,
                items: [
                    {
                        xtype: 'panel',
                        border: false,
                        autoScroll: true,
                        bodyPadding: '12 16',
                        html: bodyHtml,
                    },
                ],
                fbar: [
                    {
                        text: 'Close',
                        handler: function () {
                            subDlg.close();
                        },
                    },
                ],
            });
            subDlg.show();
        } else if (Ext.ClassManager && Ext.ClassManager.isCreated('AS.ARC.msgWindow')) {
            var dlg = Ext.create('AS.ARC.msgWindow', {
                parentWin: page.win,
                title: 'MountFix Quick Guide',
                width: 640,
                height: 380,
                iconType: 'info',
                asItems: [{ xtype: 'displayfield', value: bodyHtml }],
                fbar: [
                    {
                        text: 'Close',
                        handler: function () {
                            dlg.close();
                        },
                    },
                ],
            });
            dlg.show();
        } else {
            Ext.Msg.alert('MountFix Quick Guide', bodyHtml);
        }
    },

    unmaskAll: function () {
        this.maskStack = [];
        if (this.win && !this.win.isDestroyed && this.win.el) {
            this.win.el.unmask();
        }
    },

    maskWindow: function (message) {
        if (!this.maskStack) {
            this.maskStack = [];
        }
        message = message || 'Working...';
        this.maskStack.push(message);
        if (this.win && !this.win.isDestroyed && this.win.el) {
            this.win.el.mask(this.maskStack[this.maskStack.length - 1]);
        }
    },

    unmaskWindow: function (message) {
        if (!this.maskStack) {
            this.maskStack = [];
        }
        if (message) {
            Ext.Array.remove(this.maskStack, message);
        } else {
            this.maskStack.pop();
        }

        if (this.maskStack.length > 0) {
            if (this.win && !this.win.isDestroyed && this.win.el) {
                this.win.el.mask(this.maskStack[this.maskStack.length - 1]);
            }
        } else {
            if (this.win && !this.win.isDestroyed && this.win.el) {
                this.win.el.unmask();
            }
        }
    },
});
