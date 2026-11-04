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
                page.updateStatus('Error: Unable to save settings', true);
                page.unmaskWindow(actionMsg);
            },
        });
    },

    validate: function () {
        var page = this;
        var target = page.getSelectedVolume();
        var actionMsg = 'Validating configuration...';
        page.maskWindow(actionMsg);

        AS.ARC.ajax({
            url: AS.ARC.util.getApiUrlWithSid(page.validateApiUrl, {
                act: 'get',
                target,
            }),
            method: 'GET',
            success: function (json) {
                console.log('validated:', json);
                if (json.success && json.apps) {
                    var grid = page.win.down('#appGrid');
                    if (grid) {
                        var store = grid.getStore();
                        json.apps.forEach(function (app) {
                            var record = store.findRecord('name', app.name, 0, false, false, true);
                            if (record) {
                                record.set(app);
                            } else {
                                store.add(app);
                            }
                        });
                    }
                }
                page.updateActionsUI();
                page.unmaskWindow(actionMsg);
            },
            failure: function () {
                console.error('Failed to load validation data');
                page.unmaskWindow(actionMsg);
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
                combo.setValue(newConfig.config.targetVolume);
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

    syncBackSelectedApp: function (callbackOnComplete) {
        var page = this;
        var target = page.getSelectedVolume();
        var app = page.selectedApp && (page.selectedApp.get ? page.selectedApp.get('name') : page.selectedApp.data.name);

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

    mountSelectedApp: function () {
        this.bindMountAction('mount', 'Mounting...', 'Mounted successfully');
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
            page.updateStatus('Aplikacja ' + app + ' jest uruchomiona. Zatrzymaj ją w AppCentral przed odmontowaniem.', true);
            return;
        }

        var dlg = Ext.create('Ext.window.Window', {
            title: 'Odmontowanie: ' + app,
            width: 480,
            modal: true,
            resizable: false,
            draggable: true,
            closable: true,
            bodyPadding: '18 20 16 20',
            items: [
                {
                    xtype: 'container',
                    layout: 'hbox',
                    items: [
                        {
                            xtype: 'component',
                            width: 40,
                            height: 40,
                            margin: '0 16 0 0',
                            html: '<div style="width:36px;height:36px;border-radius:50%;background:#e6f4ff;border:1px solid #91caff;display:flex;align-items:center;justify-content:center;">' +
                                  '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#1677ff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
                                  '<circle cx="12" cy="12" r="10"></circle>' +
                                  '<path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"></path>' +
                                  '<line x1="12" y1="17" x2="12.01" y2="17"></line>' +
                                  '</svg></div>'
                        },
                        {
                            xtype: 'container',
                            flex: 1,
                            html: '<div style="font-size: 13px; font-weight: bold; color: #1f1f1f; margin-bottom: 6px;">' +
                                  'Czy chcesz wykonać Sync-back przed odmontowaniem?' +
                                  '</div>' +
                                  '<div style="font-size: 12px; color: #555; line-height: 18px;">' +
                                  'Aplikacja <b>' + Ext.String.htmlEncode(app) + '</b> zostanie odmontowana z woluminu SSD.<br><br>' +
                                  '<span style="color: #0958d9; font-weight: 500;">Zalecane:</span> Wykonaj <b>Sync-back</b>, aby przenieść najnowsze dane z SSD z powrotem na dysk źródłowy (HDD).' +
                                  '</div>'
                        }
                    ]
                }
            ],
            fbar: [
                {
                    xtype: 'button',
                    text: 'Sync-back i Odmontuj',
                    style: 'font-weight: bold; border-color: #1677ff; color: #1677ff;',
                    handler: function () {
                        dlg.close();
                        page.syncBackSelectedApp(function () {
                            page.bindMountAction('unmount', 'Unmounting...', 'Unmounted successfully');
                        });
                    }
                },
                {
                    xtype: 'button',
                    text: 'Tylko odmontuj',
                    handler: function () {
                        dlg.close();
                        page.bindMountAction('unmount', 'Unmounting...', 'Unmounted successfully');
                    }
                },
                {
                    xtype: 'button',
                    text: 'Anuluj',
                    handler: function () {
                        dlg.close();
                    }
                }
            ]
        });

        dlg.show();
    },

    bindMountAction: function (act, actionMsg, okMsg) {
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
                    page.validate();
                    page.updateActionsUI();
                } else {
                    page.updateStatus('Error: ' + ((json && json.error) || 'Operation failed'), true);
                }
            },
            failure: function () {
                page.unmaskWindow(actionMsg);
                page.updateStatus('Error: Unable to ' + act + ' application', true);
            },
        });
    },

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
                    const currentAppName = page.selectedApp && (page.selectedApp.get ? page.selectedApp.get('name') : page.selectedApp.data.name);
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
                        page.updateStatus('Error: ' + (json.message || 'Transfer failed'), true);
                        clearInterval(intervalId);
                        page.unmaskWindow(actionMsg);
                    }
                },
                failure: function () {
                    page.updateStatus('Error: Unable to check transfer status', true);
                    clearInterval(intervalId);
                    page.unmaskWindow(actionMsg);
                },
            });
        }, 500);
    },

    maskWindow: function (message) {
        message = message || 'Working...';
        this.maskStack.push(message);
        this.win && this.win.el && this.win.el.mask(this.maskStack[this.maskStack.length - 1]);
    },

    unmaskWindow: function (message) {
        if (message) {
            Ext.Array.remove(this.maskStack, message);
        } else {
            this.maskStack.pop();
        }

        if (this.maskStack.length > 0) {
            this.win && this.win.el && this.win.el.mask(this.maskStack[this.maskStack.length - 1]);
        } else {
            this.win && this.win.el && this.win.el.unmask();
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
