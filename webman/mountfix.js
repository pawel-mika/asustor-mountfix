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
                var btnApply = page.win && page.win.down('#btnApply');
                if (btnApply && btnApply.setDisabled) {
                    btnApply.setDisabled(false);
                }
                page.setMfConfig(json); // Update UI with loaded config
                page.updateActionsUI();
                page.validate();
                page.unmaskWindow(actionMsg);
            },
            failure: function (json) {
                var btnApply = page.win && page.win.down('#btnApply');
                if (btnApply && btnApply.setDisabled) {
                    btnApply.setDisabled(true);
                }
                page.updateStatus('Error: ' + ((json && json.error) || 'Failed to load configuration'), true, true);
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

    applyValidatedApps: function (apps) {
        if (!apps || !apps.length) return;
        var grid = this.win && this.win.down('#appGrid');
        if (!grid || !grid.getStore) return;
        var store = grid.getStore();
        apps.forEach(function (app) {
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
    },

    validate: function (appName, silent, options) {
        var page = this;
        var opts = options || {};
        var forceRefresh = !!opts.forceRefresh;
        var target = page.getSelectedVolume();

        // Targeted single-app validation (fast ~50-100ms, or <20ms with mode='fast')
        if (appName) {
            var singleParams = {
                act: 'get',
                target: target,
                app: appName,
            };
            if (opts.mode) {
                singleParams.mode = opts.mode;
            }
            if (!silent) {
                page.updateStatus('Validating ' + appName + '...', false, true);
            }

            page._validatingCount = (page._validatingCount || 0) + 1;
            page.updateActionsUI();

            AS.ARC.ajax({
                url: AS.ARC.util.getApiUrlWithSid(page.validateApiUrl, singleParams),
                method: 'GET',
                enableFailureReturn: true,
                success: function (json) {
                    page._validatingCount = Math.max(0, (page._validatingCount || 1) - 1);
                    if (json && json.success && json.apps) {
                        page.applyValidatedApps(json.apps);
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
            return;
        }

        // Full sweep: Tier 1 (mode=fast, zero du) unlocks actions immediately; Tier 2 (mode=sizes, cached/batched) fills sizes in background
        var seq = (page._validateSeq = (page._validateSeq || 0) + 1);
        if (!silent) {
            page.updateStatus('Validating...', false, true);
        }

        page._validatingCount = (page._validatingCount || 0) + 1;
        page.updateActionsUI();

        AS.ARC.ajax({
            url: AS.ARC.util.getApiUrlWithSid(page.validateApiUrl, {
                act: 'get',
                target: target,
                mode: 'fast',
            }),
            method: 'GET',
            enableFailureReturn: true,
            success: function (json) {
                page._validatingCount = Math.max(0, (page._validatingCount || 1) - 1);
                if (seq !== page._validateSeq) {
                    page.updateActionsUI();
                    return;
                }
                if (json && json.success && json.apps) {
                    page.applyValidatedApps(json.apps);
                }
                page.updateActionsUI();

                var sizeParams = {
                    act: 'get',
                    target: target,
                    mode: 'sizes',
                };
                if (forceRefresh) {
                    sizeParams.refresh = '1';
                }
                if (!silent) {
                    page.updateStatus(forceRefresh ? 'Refreshing sizes...' : 'Loading sizes...', false, true);
                }

                AS.ARC.ajax({
                    url: AS.ARC.util.getApiUrlWithSid(page.validateApiUrl, sizeParams),
                    method: 'GET',
                    enableFailureReturn: true,
                    success: function (sizeJson) {
                        if (seq !== page._validateSeq) {
                            return;
                        }
                        if (sizeJson && sizeJson.success && sizeJson.apps) {
                            page.applyValidatedApps(sizeJson.apps);
                        }
                        if (!silent) {
                            page.updateStatus('', false);
                        }
                    },
                    failure: function () {
                        if (seq === page._validateSeq && !silent) {
                            page.updateStatus('', false);
                        }
                    },
                });
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
                    page.updateStatus('Copying ' + app + ': 0%', false, true);
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
                        page.updateStatus('Sync-back ' + app + ': 0%', false, true);
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
                    // Optimistic UI update (IDEAS.md §1 D.2) before silent background reconciliation
                    var record = page.selectedApp;
                    if (record && record.set) {
                        var isMount = act === 'mount';
                        var optimistic = {
                            mounted: isMount
                                ? {
                                      source: json.bindSource || (target + '/AppCentral/' + app),
                                      target: json.bindTarget || ('/volume1/.@plugins/AppCentral/' + app),
                                  }
                                : null,
                            mismatch: null,
                        };
                        if (json.configUpdated !== false) {
                            optimistic.configured = isMount;
                            optimistic.selected = isMount;
                        }
                        record.set(optimistic);
                        if (record.commit) {
                            record.commit();
                        }
                    }
                    page.updateStatus(json.message || okMsg, false);
                    page.updateActionsUI();
                    if (typeof onSuccessCallback === 'function') {
                        onSuccessCallback();
                    } else {
                        page.validate(app, true, { mode: 'fast' });
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

    formatTransferProgress: function (label, progress, lastLine) {
        var msg = label + ': ' + progress + '%';
        if (lastLine) {
            var m = String(lastLine).match(/\b(\d+(?:\.\d+)?[kMGT]?B\/s)\b/i);
            if (m && m[1]) {
                msg += ' (' + m[1] + ')';
            }
        }
        return msg;
    },

    updateMaskMessage: function (message) {
        if (!this.win || this.win.isDestroyed || !this.win.el) return;
        var msgEl = this.win.el.down && (this.win.el.down('.x-mask-msg-text') || this.win.el.down('.x-mask-msg div'));
        if (msgEl && msgEl.update) {
            msgEl.update(Ext.String.htmlEncode(message));
            return;
        }
        this.win.el.mask(message);
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
        var initialMask = baseLabel + ': 0%';
        page.maskWindow(initialMask);
        page.updateStatus(initialMask, false, true);
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
                        var statusMsg = page.formatTransferProgress(
                            actionLabel || (appName ? ('Transfer ' + appName) : 'Transfer'),
                            progress,
                            lastLine,
                        );
                        page.updateMaskMessage(statusMsg);
                        page.updateStatus(statusMsg, false, true);

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

        page._pollTimer = setTimeout(poll, 200);
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
                    // Optimistic UI update (IDEAS.md §1 D.2)
                    var grid = page.win.down('#appGrid');
                    var store = grid && grid.getStore && grid.getStore();
                    var delRec = (store && store.findRecord && store.findRecord('name', app, 0, false, false, true)) || page.selectedApp;
                    if (delRec && delRec.set) {
                        delRec.set({ existsInTarget: false, targetSize: '0', targetSizeKb: 0 });
                        if (delRec.commit) delRec.commit();
                    }
                    page.updateActionsUI();
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
            '<b>HDD Monitor (also useful on HDD-only NAS):</b><br>' +
            'Even without an SSD volume, you can use the <b>HDD Monitor</b> tab (read-only, all state in RAM <code>/tmp</code>) to see which processes or AppCentral packages wake your mechanical drives from standby.<br><br>' +
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
                height: 410,
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


/**
 * MountFix HDD Activity Monitor (ExtJS 4 Mixin)
 */
Ext.define('AS.ARC.apps.MountFix.Diskwatch', {
    diskwatchApiUrl: AS.ARC.util.getUserAppsPath() + 'MountFix/' + 'diskwatch.cgi',

    formatDwKb: function (kb) {
        var n = parseInt(kb, 10) || 0;
        if (n <= 0) return '<span style="color:#9ca3af;">—</span>';
        if (n < 1024) return n + 'K';
        if (n < 1048576) return (n / 1024).toFixed(1) + 'M';
        return (n / 1048576).toFixed(1) + 'G';
    },

    formatDwSeconds: function (sec, forceHours) {
        var s = Math.max(0, parseInt(sec, 10) || 0);
        if (forceHours || s >= 3600) {
            var h = Math.floor(s / 3600);
            var rem = s % 3600;
            var m = Math.floor(rem / 60);
            var r = rem % 60;
            return (h < 10 ? '0' : '') + h + ':' + (m < 10 ? '0' : '') + m + ':' + (r < 10 ? '0' : '') + r;
        }
        var mins = Math.floor(s / 60);
        var secs = s % 60;
        return (mins < 10 ? '0' : '') + mins + ':' + (secs < 10 ? '0' : '') + secs;
    },

    createDiskwatchPanel: function () {
        var fn = this;

        var durationStore = Ext.create('Ext.data.Store', {
            fields: ['value', 'label'],
            data: [
                { value: 30, label: '30 sec (1s)' },
                { value: 60, label: '1 min (1s)' },
                { value: 300, label: '5 min (3s)' },
                { value: 600, label: '10 min (3s)' },
                { value: 1200, label: '20 min (3s)' },
                { value: 1800, label: '30 min (5s)' },
                { value: 2700, label: '45 min (5s)' },
                { value: 3600, label: '1 hour (5s)' },
                { value: 7200, label: '2 hours (10s)' },
                { value: 10800, label: '3 hours (10s)' },
                { value: 14400, label: '4 hours (10s)' },
                { value: 21600, label: '6 hours (10s)' },
                { value: 28800, label: '8 hours (10s)' },
                { value: 43200, label: '12 hours (10s)' },
            ],
        });

        var collectorStore = Ext.create('Ext.data.Store', {
            fields: ['value', 'label'],
            data: [
                { value: 'auto', label: 'Auto (iotop-static)' },
                { value: 'iotop-static', label: 'iotop-static' },
                { value: 'proc-io', label: '/proc/io (script)' },
            ],
        });

        var culpritsStore = Ext.create('Ext.data.Store', {
            fields: ['key', 'process', 'appName', 'hits', 'readKB', 'writeKB', 'dState', 'lastSeen', 'relocationStatus'],
            data: [],
        });

        var timelineStore = Ext.create('Ext.data.Store', {
            fields: ['time', 'devices', 'processes'],
            data: [],
        });

        return {
            xtype: 'panel',
            itemId: 'diskwatchPanel',
            title: 'HDD Monitor',
            border: false,
            layout: {
                type: 'vbox',
                align: 'stretch',
            },
            bodyPadding: '8 16',
            items: [
                {
                    xtype: 'fieldset',
                    title: 'HDD Activity Capture (Read-Only, tmpfs)',
                    collapsible: false,
                    layout: 'anchor',
                    items: [
                        {
                            xtype: 'fieldcontainer',
                            anchor: '100%',
                            height: 32,
                            layout: {
                                type: 'hbox',
                                align: 'middle',
                            },
                            items: [
                                {
                                    xtype: 'combo',
                                    itemId: 'dwDuration',
                                    fieldLabel: 'Duration',
                                    labelWidth: 52,
                                    width: 185,
                                    store: durationStore,
                                    queryMode: 'local',
                                    displayField: 'label',
                                    valueField: 'value',
                                    value: 300,
                                    editable: false,
                                    triggerAction: 'all',
                                    margin: '0 8 0 0',
                                },
                                {
                                    xtype: 'combo',
                                    itemId: 'dwCollector',
                                    fieldLabel: 'Collector',
                                    labelWidth: 54,
                                    width: 195,
                                    store: collectorStore,
                                    queryMode: 'local',
                                    displayField: 'label',
                                    valueField: 'value',
                                    value: 'auto',
                                    editable: false,
                                    triggerAction: 'all',
                                    margin: '0 8 0 0',
                                },
                                {
                                    xtype: 'button',
                                    itemId: 'btnDwStart',
                                    text: 'Start',
                                    width: 64,
                                    margin: '0 6 0 0',
                                    handler: function () {
                                        fn.startDiskwatchCapture();
                                    },
                                },
                                {
                                    xtype: 'button',
                                    itemId: 'btnDwStop',
                                    text: 'Stop',
                                    width: 64,
                                    disabled: true,
                                    margin: '0 6 0 0',
                                    handler: function () {
                                        fn.stopDiskwatchCapture();
                                    },
                                },
                                {
                                    xtype: 'button',
                                    itemId: 'btnDwRefresh',
                                    text: 'Refresh',
                                    width: 78,
                                    margin: '0 10 0 0',
                                    handler: function () {
                                        fn.refreshDiskwatchStatus();
                                    },
                                },
                                {
                                    xtype: 'component',
                                    itemId: 'dwProgressText',
                                    flex: 1,
                                    height: 24,
                                    style: 'font-size: 12px; line-height: 24px; color: #374151; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;',
                                    html: 'Idle',
                                },
                                {
                                    xtype: 'component',
                                    itemId: 'dwCollectorBadge',
                                    width: 125,
                                    height: 22,
                                    style: 'font-size: 11px; line-height: 18px; color: #4b5563; background: #f3f4f6; border: 1px solid #d1d5db; border-radius: 3px; padding: 1px 6px; margin-left: 6px; white-space: nowrap; text-align: center;',
                                    html: 'active: —',
                                },
                            ],
                        },
                        {
                            xtype: 'component',
                            itemId: 'dwHddSummary',
                            anchor: '100%',
                            height: 20,
                            margin: '6 0 0 0',
                            style: 'font-size: 11px; color: #4b5563; line-height: 20px;',
                            html: 'Click <b>Start</b> to monitor physical HDD activity. All state stays in RAM (<code>/tmp</code>) and never wakes sleeping drives.',
                        },
                    ],
                },
                {
                    xtype: 'tabpanel',
                    itemId: 'dwResultTabs',
                    flex: 1,
                    margin: '8 0 0 0',
                    border: true,
                    activeTab: 0,
                    items: [
                        {
                            xtype: 'grid',
                            itemId: 'dwCulpritsGrid',
                            title: 'Summary (Top Culprits)',
                            store: culpritsStore,
                            border: false,
                            columnLines: false,
                            viewConfig: {
                                emptyText: '<div style="padding:16px;color:#6b7280;">No HDD activity recorded yet.</div>',
                                deferEmptyText: false,
                            },
                            columns: [
                                {
                                    text: 'Process',
                                    dataIndex: 'process',
                                    flex: 1,
                                    menuDisabled: true,
                                    renderer: function (v) {
                                        return Ext.String.htmlEncode(v || '');
                                    },
                                },
                                {
                                    text: 'AppCentral',
                                    dataIndex: 'appName',
                                    width: 125,
                                    menuDisabled: true,
                                    renderer: function (v) {
                                        return v ? '<b>' + Ext.String.htmlEncode(v) + '</b>' : '<span style="color:#9ca3af;">—</span>';
                                    },
                                },
                                {
                                    text: 'Hits',
                                    dataIndex: 'hits',
                                    width: 55,
                                    align: 'right',
                                    menuDisabled: true,
                                },
                                {
                                    text: 'Read',
                                    dataIndex: 'readKB',
                                    width: 75,
                                    align: 'right',
                                    menuDisabled: true,
                                    renderer: function (v) {
                                        return fn.formatDwKb(v);
                                    },
                                },
                                {
                                    text: 'Write',
                                    dataIndex: 'writeKB',
                                    width: 75,
                                    align: 'right',
                                    menuDisabled: true,
                                    renderer: function (v) {
                                        return fn.formatDwKb(v);
                                    },
                                },
                                {
                                    text: 'D-State',
                                    dataIndex: 'dState',
                                    width: 65,
                                    align: 'right',
                                    menuDisabled: true,
                                },
                                {
                                    text: 'Last Seen',
                                    dataIndex: 'lastSeen',
                                    width: 78,
                                    menuDisabled: true,
                                },
                                {
                                    text: 'Relocation',
                                    dataIndex: 'relocationStatus',
                                    width: 170,
                                    menuDisabled: true,
                                    renderer: function (v) {
                                        if (v === 'hdd_relocatable') {
                                            return '<span style="color:#b45309; font-weight:bold;">Still on HDD — can relocate</span>';
                                        }
                                        if (v === 'ssd_mounted') {
                                            return '<span style="color:#16a34a;">Mounted on SSD</span>';
                                        }
                                        return '<span style="color:#6b7280;">System / Kernel</span>';
                                    },
                                },
                            ],
                        },
                        {
                            xtype: 'grid',
                            itemId: 'dwTimelineGrid',
                            title: 'Timeline',
                            store: timelineStore,
                            border: false,
                            columnLines: false,
                            viewConfig: {
                                emptyText: '<div style="padding:16px;color:#6b7280;">No HDD wakeup events in timeline yet.</div>',
                                deferEmptyText: false,
                            },
                            columns: [
                                {
                                    text: 'Time',
                                    dataIndex: 'time',
                                    width: 78,
                                    menuDisabled: true,
                                },
                                {
                                    text: 'HDD Devices (+R/+W)',
                                    dataIndex: 'devices',
                                    width: 230,
                                    menuDisabled: true,
                                    renderer: function (v) {
                                        return Ext.String.htmlEncode(v || '');
                                    },
                                },
                                {
                                    text: 'Active Processes',
                                    dataIndex: 'processes',
                                    flex: 1,
                                    menuDisabled: true,
                                    renderer: function (v) {
                                        return Ext.String.htmlEncode(v || '');
                                    },
                                },
                            ],
                        },
                    ],
                },
            ],
        };
    },

    stopDiskwatchPolling: function () {
        this._dwPollActive = false;
        if (this._dwPollTimer) {
            clearTimeout(this._dwPollTimer);
            this._dwPollTimer = null;
        }
    },

    scheduleDiskwatchPoll: function () {
        var page = this;
        if (!page._dwPollActive) {
            return;
        }
        if (page._dwPollTimer) {
            clearTimeout(page._dwPollTimer);
        }
        page._dwPollTimer = setTimeout(function () {
            page._dwPollTimer = null;
            if (!page._dwPollActive || (page.win && page.win.isDestroyed)) {
                return;
            }
            page.refreshDiskwatchStatus(true);
        }, 2000);
    },

    startDiskwatchCapture: function () {
        var page = this;
        var combo = page.win.down('#dwDuration');
        var collectorCombo = page.win.down('#dwCollector');
        var duration = (combo && combo.getValue()) || 300;
        var collector = (collectorCombo && collectorCombo.getValue()) || 'auto';
        var btnStart = page.win.down('#btnDwStart');
        var btnStop = page.win.down('#btnDwStop');
        if (btnStart) btnStart.setDisabled(true);

        AS.ARC.ajax({
            url: AS.ARC.util.getApiUrlWithSid(page.diskwatchApiUrl, {
                act: 'start',
                duration: duration,
                collector: collector,
            }),
            method: 'POST',
            enableFailureReturn: true,
            success: function (json) {
                if (json && json.success) {
                    if (btnStop) btnStop.setDisabled(false);
                    page._dwPollActive = true;
                    page.refreshDiskwatchStatus(true);
                } else {
                    if (btnStart) btnStart.setDisabled(false);
                    var err = (json && json.result && json.result.error) || (json && json.error) || 'Failed to start HDD Monitor';
                    page.updateStatus('Error: ' + err, true);
                }
            },
            failure: function (json) {
                if (btnStart) btnStart.setDisabled(false);
                var err = (json && json.result && json.result.error) || (json && json.error) || 'Failed to start HDD Monitor';
                page.updateStatus('Error: ' + err, true);
            },
        });
    },

    stopDiskwatchCapture: function () {
        var page = this;
        var btnStop = page.win.down('#btnDwStop');
        if (btnStop) btnStop.setDisabled(true);
        page.stopDiskwatchPolling();

        AS.ARC.ajax({
            url: AS.ARC.util.getApiUrlWithSid(page.diskwatchApiUrl, { act: 'stop' }),
            method: 'POST',
            enableFailureReturn: true,
            success: function () {
                page.refreshDiskwatchStatus(false);
            },
            failure: function () {
                page.refreshDiskwatchStatus(false);
            },
        });
    },

    refreshDiskwatchStatus: function (fromPoll) {
        var page = this;
        if (page.win && page.win.isDestroyed) {
            page.stopDiskwatchPolling();
            return;
        }

        AS.ARC.ajax({
            url: AS.ARC.util.getApiUrlWithSid(page.diskwatchApiUrl, { act: 'status' }),
            method: 'GET',
            enableFailureReturn: true,
            success: function (json) {
                if (page.win && page.win.isDestroyed) {
                    page.stopDiskwatchPolling();
                    return;
                }
                if (json && json.success && json.result) {
                    page.applyDiskwatchStatus(json.result);
                    if (json.result.state === 'running') {
                        page._dwPollActive = true;
                        page.scheduleDiskwatchPoll();
                    } else {
                        page.stopDiskwatchPolling();
                    }
                } else if (fromPoll) {
                    page.stopDiskwatchPolling();
                }
            },
            failure: function () {
                page.stopDiskwatchPolling();
                var btnStart = page.win && !page.win.isDestroyed && page.win.down('#btnDwStart');
                var btnStop = page.win && !page.win.isDestroyed && page.win.down('#btnDwStop');
                var combo = page.win && !page.win.isDestroyed && page.win.down('#dwDuration');
                var collectorCombo = page.win && !page.win.isDestroyed && page.win.down('#dwCollector');
                if (btnStart) btnStart.setDisabled(false);
                if (btnStop) btnStop.setDisabled(true);
                if (combo) combo.setDisabled(false);
                if (collectorCombo) collectorCombo.setDisabled(false);
            },
        });
    },

    applyDiskwatchStatus: function (res) {
        var page = this;
        if (!page.win || page.win.isDestroyed || !res) return;

        var running = res.state === 'running';
        var btnStart = page.win.down('#btnDwStart');
        var btnStop = page.win.down('#btnDwStop');
        var combo = page.win.down('#dwDuration');
        var collectorCombo = page.win.down('#dwCollector');
        var progressEl = page.win.down('#dwProgressText');
        var badgeEl = page.win.down('#dwCollectorBadge');
        var summaryEl = page.win.down('#dwHddSummary');
        var culpritsGrid = page.win.down('#dwCulpritsGrid');
        var timelineGrid = page.win.down('#dwTimelineGrid');

        if (btnStart) btnStart.setDisabled(running);
        if (btnStop) btnStop.setDisabled(!running);
        if (combo) combo.setDisabled(running);
        if (collectorCombo) collectorCombo.setDisabled(running);

        if (badgeEl) {
            var col = res.collector || 'proc-io';
            badgeEl.update('active: <b>' + Ext.String.htmlEncode(col) + '</b>');
        }

        if (progressEl) {
            var stateLabel = 'Idle';
            var useHours = (parseInt(res.duration, 10) || 0) >= 3600;
            if (running) {
                stateLabel =
                    '<span style="color:#007dff; font-weight:bold;">Recording</span> ' +
                    page.formatDwSeconds(res.elapsed, useHours) +
                    ' / ' +
                    page.formatDwSeconds(res.duration, useHours) +
                    ' (' +
                    (res.interval || 1) +
                    's)';
            } else if (res.state === 'done') {
                stateLabel =
                    '<span style="color:#16a34a; font-weight:bold;">Completed</span> (' +
                    page.formatDwSeconds(res.elapsed, useHours) +
                    ' / ' +
                    page.formatDwSeconds(res.duration, useHours) +
                    ')';
            } else if (res.state === 'stopped') {
                stateLabel =
                    '<span style="color:#b45309; font-weight:bold;">Stopped</span> (' +
                    page.formatDwSeconds(res.elapsed, useHours) +
                    ' / ' +
                    page.formatDwSeconds(res.duration, useHours) +
                    ')';
            } else if (res.state === 'error') {
                stateLabel = '<span style="color:#cc0000; font-weight:bold;">Error:</span> ' + Ext.String.htmlEncode(res.error || '');
            }
            progressEl.update(stateLabel);
        }

        if (summaryEl) {
            var powerParts = [];
            if (Ext.isArray(res.hddPower) && res.hddPower.length > 0) {
                res.hddPower.forEach(function (d) {
                    var st = d.state || 'unknown';
                    var stColor = st === 'standby' || st === 'sleeping' ? '#16a34a' : st === 'unknown' ? '#6b7280' : '#d97706';
                    powerParts.push(
                        '<b>' + Ext.String.htmlEncode(d.disk) + '</b>: <span style="color:' + stColor + ';">' + Ext.String.htmlEncode(st) + '</span>',
                    );
                });
            } else {
                powerParts.push('no rotational HDDs detected');
            }
            var rStr = page.formatDwKb(res.hddReadKB);
            var wStr = page.formatDwKb(res.hddWriteKB);
            summaryEl.update(
                'HDD Power: ' +
                    powerParts.join(', ') +
                    ' &nbsp;|&nbsp; Physical HDD I/O: <b>R ' +
                    rStr +
                    ' / W ' +
                    wStr +
                    '</b> &nbsp;|&nbsp; Wakeup events: <b>' +
                    (res.eventCount || 0) +
                    '</b>',
            );
        }

        if (culpritsGrid && culpritsGrid.getStore) {
            culpritsGrid.getStore().loadData(res.culprits || []);
        }
        if (timelineGrid && timelineGrid.getStore) {
            timelineGrid.getStore().loadData(res.timeline || []);
        }
    },
});


/**
 * MountFix Core
 */
Ext.define('AS.ARC.apps.MountFix.core', {
    extend: 'Ext.util.Observable',
    mixins: ['AS.ARC.apps.MountFix.Actions', 'AS.ARC.apps.MountFix.Diskwatch'],

    constructor: function (config) {
        Ext.apply(this, config);
        this.maskStack = [];
        this._pollTimer = null;
        this._pollActive = false;
        this._dwPollTimer = null;
        this._dwPollActive = false;
        this._statusFadeTimer = null;
        this._validatingCount = 0;
        this._validateSeq = 0;
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

        // Main form panel (Tab 1: App Relocation)
        var mainPanel = Ext.create('AS.ARC.formBase', {
            itemId: 'mainPanel',
            title: 'App Relocation',
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
                            xtype: 'fieldcontainer',
                            anchor: '100%',
                            height: 28,
                            layout: {
                                type: 'hbox',
                                align: 'middle',
                            },
                            items: [
                                {
                                    flex: 1,
                                    margin: '0 8 0 0',
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
                                {
                                    xtype: 'button',
                                    itemId: 'btnRefresh',
                                    text: 'Refresh',
                                    width: 78,
                                    tooltip: 'Re-check mount state and recalculate disk sizes (bypasses size cache)',
                                    handler: function () {
                                        if (!fn.cgiConfig || !fn.cgiConfig.config) {
                                            fn.loadConfig();
                                        } else {
                                            fn.validate(null, false, { forceRefresh: true });
                                        }
                                    },
                                },
                            ],
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
                            columnLines: false,
                            scrollable: true,
                            // ExtJS 4 fieldset+fit does not subtract legend height (~28px), clipping the last grid row without bottom padding
                            padding: '0 0 28 0',
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
                                    width: 82,
                                    resizable: false,
                                    processEvent: function () {
                                        return false;
                                    },
                                    renderer: function (value) {
                                        var color = value ? '#16a34a' : '#6b7280';
                                        var text = value ? 'Running' : 'Stopped';
                                        return '<span style="color:' + color + '; font-size:11px;">● ' + text + '</span>';
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
                                    width: 90,
                                    align: 'right',
                                    menuDisabled: true,
                                    renderer: function (v) {
                                        if (v === '...') return '<span style="color:#9ca3af;">...</span>';
                                        return v && v !== '0' ? v : '<span style="color:#9ca3af;">—</span>';
                                    },
                                },
                                {
                                    text: 'Target Size',
                                    dataIndex: 'targetSize',
                                    width: 90,
                                    align: 'right',
                                    menuDisabled: true,
                                    renderer: function (v) {
                                        if (v === '...') return '<span style="color:#9ca3af;">...</span>';
                                        return v && v !== '0' ? v : '<span style="color:#9ca3af;">—</span>';
                                    },
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
                            defaults: {
                                margin: '0 8 0 0',
                            },
                            items: [
                                {
                                    xtype: 'button',
                                    text: 'Copy to target',
                                    itemId: 'btnCopyToTarget',
                                    handler: function () {
                                        fn.migrateSelectedApp();
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
                                {
                                    xtype: 'button',
                                    text: 'Delete target',
                                    itemId: 'btnDeleteTarget',
                                    margin: '0 0 0 8',
                                    handler: function () {
                                        fn.deleteSelectedAppTarget();
                                    },
                                },
                            ],
                        },
                        {
                            xtype: 'component',
                            itemId: 'actionHint',
                            margin: '6 0 0 0',
                            height: 18,
                            style: 'color: #b45309; font-size: 11px; line-height: 18px;',
                            html: '&nbsp;',
                        },
                        {
                            xtype: 'checkbox',
                            name: 'enableSysctlTuning',
                            itemId: 'chkSysctlTuning',
                            boxLabel: 'Apply kernel VM/writeback sysctl tuning on boot (swappiness=1, dirty_writeback=60s)',
                            margin: '4 0 0 0',
                        },
                    ],
                },
            ],

            // --- FOOTER ---
            dockedItems: [
                {
                    xtype: 'toolbar',
                    dock: 'bottom',
                    ui: 'footer',
                    padding: '8 16',
                    layout: {
                        type: 'hbox',
                        align: 'middle',
                    },
                    items: [
                        {
                            xtype: 'component',
                            itemId: 'displayVersion',
                            html: '',
                            height: 28,
                            style: 'color: #888; font-size: 11px; line-height: 28px;',
                        },
                        {
                            xtype: 'component',
                            itemId: 'statusInfo',
                            flex: 1,
                            height: 28,
                            html: '',
                            style: 'color: #333; font-size: 12px; line-height: 28px; text-align: right; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;',
                            margin: '0 14 0 12',
                        },
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
                },
            ],
        });

        // Compute balanced desktop window size (~80% viewport height, landscape proportions)
        var vh = (Ext.Element && Ext.Element.getViewportHeight ? Ext.Element.getViewportHeight() : window.innerHeight) || 720;
        var vw = (Ext.Element && Ext.Element.getViewportWidth ? Ext.Element.getViewportWidth() : window.innerWidth) || 1024;
        var winHeight = Math.max(540, Math.min(Math.floor(vh * 0.8), vh - 90));
        var winWidth = Math.max(760, Math.min(Math.floor(vw * 0.78), 1020));

        // Top-level tabs: App Relocation + HDD Monitor
        var diskwatchPanel = fn.createDiskwatchPanel();
        var mainTabPanel = Ext.create('Ext.tab.Panel', {
            itemId: 'mfTabPanel',
            border: false,
            activeTab: 0,
            items: [mainPanel, diskwatchPanel],
            listeners: {
                tabchange: function (tp, newCard) {
                    if (newCard && newCard.itemId === 'diskwatchPanel') {
                        fn.refreshDiskwatchStatus(false);
                    }
                },
            },
        });

        // Creating window through ADM desktop
        this.win = this.desktop.createWindow({
            app: fn.app,
            id: fn.id,
            title: 'MountFix',
            width: winWidth,
            height: winHeight,
            minWidth: 760,
            layout: 'fit',
            taskIcon: '../apps/MountFix/images/icon-app-task.png',
            // ADM AS.ARC.appWindow reads exTitleButtons (not tools) and applies cls to the inner <img>
            exTitleButtons: [
                {
                    cls: 'x-tool-question',
                    tooltip: 'MountFix Quick Guide',
                    handler: function () {
                        fn.showHelpDialog();
                    },
                },
            ],
            items: [mainTabPanel],
        });

        // Attach via win.on() so AS.ARC.appWindow.prototype.listeners (Ps scrollbars, resize, focus) is preserved
        this.win.on('afterrender', function () {
            fn.loadConfig();
        });
        this.win.on('beforeclose', function () {
            fn.stopMigrationMonitor();
            fn.stopDiskwatchPolling();
            if (fn._statusFadeTimer) {
                clearTimeout(fn._statusFadeTimer);
                fn._statusFadeTimer = null;
            }
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


