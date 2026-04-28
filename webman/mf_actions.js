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

    cgiConfig: {}, // Placeholder for config loaded from CGI

    selectedApp: null, // Currently selected app in the grid

    getSelectedVolume: function () {
        return this.win.down('combo[name=targetVolume]')?.getValue() ?? null;
    },

    // refresh ui elements related to actions based on current state (like selected app)
    updateActionsUI: function () {
        var btn = this.win.down('#btnCopyToTarget');
        if (!btn) return;

        if (this.selectedApp) {
            btn.setText('Copy to target: ' + this.selectedApp.get('name'));
            btn.enable();
        } else {
            btn.setText('Copy to target');
            btn.disable();
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

    migrateSelectedApp: function () {
        var page = this;
        var actionMsg = 'Copyting application...';
        var target = page.getSelectedVolume();
        var app = page.selectedApp.data.name;
        page.maskWindow(actionMsg);

        AS.ARC.ajax({
            url: AS.ARC.util.getApiUrlWithSid(page.migrateApiUrl, { act: 'migrate', target, app }),
            params: Ext.encode(page.getMfConfig()),
            success: function (json) {
                page.updateStatus('Copying started successfully', false);

                page.unmaskWindow(actionMsg);
            },
            failure: function (json) {
                page.updateStatus('Error: Unable to start copying', true);
                page.unmaskWindow(actionMsg);
            },
        });
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
