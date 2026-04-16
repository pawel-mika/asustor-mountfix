/**
 * MountFix Application for ASUSTOR ADM
 */

// 1. Definition of the application core (UI and Logic)
Ext.define("AS.ARC.apps.MountFix.core", {
    extend: "Ext.util.Observable",

    // Paths to API (adjust if folder name is different)
    appsApiUrl: AS.ARC.util.getUserAppsPath() + "MountFix/" + "apps.cgi",
    configApiUrl: AS.ARC.util.getUserAppsPath() + "MountFix/" + "config.cgi",
    validateApiUrl: AS.ARC.util.getUserAppsPath() + "MountFix/" + "validate.cgi",

    cgiConfig: {}, // Placeholder for config loaded from CGI

    constructor: function (config) {
        Ext.apply(this, config);
        this.callParent();
        this.init();
    },

    init: function () {
        var fn = this;

        // Store for the list of applications in the Sources section
        var appStore = Ext.create("Ext.data.Store", {
            fields: ["name", "enabled", "status", "sourceSize", "targetSize"],
            data: []
        });

        this.loadConfig(); // Load initial config
        this.getApps(); // Load list of apps

        // Main form panel (window base)
        var mainPanel = Ext.create('AS.ARC.formBase', {
            itemId: 'mainPanel',
            cls: 'as-page-panel',
            border: false,
            // Change layout to vbox to manage vertical space
            layout: {
                type: 'vbox',
                align: 'stretch' // Makes items take full width
            },
            bodyPadding: '15 20 15 15',
            autoScroll: true,
            items: [
                // --- SECTION 1: TARGET ---
                {
                    xtype: 'fieldset',
                    title: "Target Volume",
                    collapsible: false,
                    defaults: { anchor: '100%', labelWidth: 120 },
                    items: [{
                        xtype: 'combo',
                        fieldLabel: 'Select Volume',
                        name: 'targetVolume',
                        store: {
                            fields: ['volume', 'mountPoint', 'freeSpace'],
                            data: []
                        },
                        queryMode: 'local',
                        displayField: 'volume',
                        valueField: 'volume',
                        editable: false,
                        triggerAction: 'all',
                        tpl: Ext.create('Ext.XTemplate',
                            '<tpl for=".">',
                            '<div class="x-boundlist-item">{volume} ({mountPoint}) - Free: {freeSpace}</div>',
                            '</tpl>'
                        ),
                        listeners: {
                            change: function (combo, newValue) {
                                fn.validate();
                            }
                        }
                    }]
                },

                // --- SECTION 2: SOURCES (Grid with applications) ---
                {
                    xtype: 'fieldset',
                    title: "Sources & Applications",
                    flex: 1,
                    layout: 'fit',
                    // height: 220,
                    margin: '15 0',
                    items: [{
                        xtype: 'grid',
                        itemId: 'appGrid',
                        store: appStore,
                        border: true,
                        columnLines: true,
                        columns: [
                            {
                                xtype: 'checkcolumn',
                                text: 'Fix',
                                dataIndex: 'enabled',
                                width: 50,
                                resizable: false
                            },
                            {
                                text: "Application Name",
                                dataIndex: "name",
                                flex: 1,
                                menuDisabled: true
                            },
                            {
                                text: "Current Status",
                                dataIndex: "status",
                                width: 100,
                                renderer: function (val) {
                                    var color = (val === 'Ready') ? 'green' : 'gray';
                                    return '<span style="color:' + color + ';">' + val + '</span>';
                                }
                            },
                            {
                                text: "Source Size",
                                dataIndex: "sourceSize",
                                flex: 1,
                                menuDisabled: true
                            },
                            {
                                text: "Target Size",
                                dataIndex: "targetSize",
                                flex: 1,
                                menuDisabled: true
                            },
                        ]
                    }]
                },

                // --- SECTION 3: MISC ---
                {
                    xtype: 'fieldset',
                    title: "Misc Options",
                    defaults: { anchor: '100%', labelWidth: 120 },
                    items: [
                        {
                            xtype: 'checkbox',
                            boxLabel: 'Auto-repair mount points on system boot',
                            name: 'autoRepair',
                            checked: true
                        },
                        {
                            xtype: 'displayfield',
                            fieldLabel: 'Engine Version',
                            value: 'v1.2.0 (Stable)'
                        }
                    ]
                }
            ],

            // --- PROFESSIONAL FOOTER (Compatible with miniDLNA/ADM) ---
            fbar: [
                {
                    xtype: 'container',
                    itemId: 'statusInfo',
                    html: '',
                    height: 20,
                    style: 'color: #333; font-size: 12px; font-weight: bold;',
                    margin: '0 10 0 10'
                },
                { xtype: 'tbfill' }, // Filler moves buttons to the right
                {
                    xtype: 'button',
                    text: "Apply",
                    itemId: 'btnApply',
                    width: 85,
                    handler: function () {
                        fn.saveConfig();
                    }
                },
                {
                    xtype: 'button',
                    text: "Cancel",
                    width: 85,
                    handler: function () {
                        fn.win.close();
                    }
                }
            ]
        });

        // Creating window through ADM desktop
        this.win = this.desktop.createWindow({
            app: fn.app,
            id: fn.id,
            title: "MountFix",
            width: 480,
            height: 600,
            layout: "fit",
            iconCls: "as-app-icon-MountFix",
            items: [mainPanel],
            listeners: {
                afterrender: function (win) {
                    // Initialization of ADM scrollbar (PerfectScrollbar)
                    if (window.Ps) {
                        Ps.initialize(win.body.dom);
                    }
                }
            }
        });
    },

    getSelectedVolume: function () {
        return this.win.down('combo[name=targetVolume]')?.getValue() ?? null;
    },

    // Notification function in footer (fadeIn/fadeOut effect)
    updateStatus: function (message, isError) {
        var statusCont = this.win.down('#statusInfo');
        var color = isError ? '#cc0000' : '#007dff';
        // var icon = isError ? 'alert.png' : 'common-icon_16X16_status_tip_ok.png';
        // statusCont.update('<img src="resources/images/icons/common_16x16/' + icon + '" style="vertical-align:middle; margin-right:5px;">' + message);
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
            url: AS.ARC.util.getApiUrlWithSid(page.appsApiUrl, { act: "get" }),
            method: "GET",
            success: function (json) {
                console.log("Apps:", json);
            },
            failure: function () {
                console.error("Failed to load apps");
            },
        });
    },

    // Example of loading data from your CGI
    loadConfig: function () {
        var page = this;

        AS.ARC.ajax({
            url: AS.ARC.util.getApiUrlWithSid(page.configApiUrl, { act: "get" }),
            method: "GET",
            success: function (json) {
                console.log("Config loaded:", json);
                page.cgiConfig = json; // Store config for later use
                page.setConfig(page.cgiConfig); // Update UI with loaded config
                page.validate();
            },
            failure: function () {
                console.error("Failed to load config");
            },
        });
    },

    saveConfig: function () {
        var page = this;
        // Masking window during save
        page.win.el.mask("Saving changes...");
        // Simulation of sending to CGI
        AS.ARC.ajax({
            url: AS.ARC.util.getApiUrlWithSid(page.configApiUrl, { act: "set" }),
            params: Ext.encode(page.getConfig()),
            success: function (json) {
                page.win.el.unmask();
                page.updateStatus("Settings applied successfully", false);
            },
            failure: function (json) {
                page.win.el.unmask();
                page.updateStatus("Error: Unable to save settings", true);
            },
        });
    },

    validate: function () {
        var page = this;
        var target = page.getSelectedVolume();

        AS.ARC.ajax({
            url: AS.ARC.util.getApiUrlWithSid(page.validateApiUrl, { act: "get", target }),
            method: "GET",
            success: function (json) {
                console.log("validated:", json);
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
            },
            failure: function () {
                console.error("Failed to load validation data");
            },
        });
    },

    setConfig: function (newConfig) {
        var page = this;
        var selectedApps = newConfig.config?.selectedApps?.filter(a => a.enabled).map(({ name }) => name) || [];
        var mappedApps = (newConfig.allApps || []).map(name => ({ name, enabled: selectedApps.includes(name), status: '...' }));
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

    getConfig: function () {
        var page = this;
        var panel = page.win.down('#mainPanel');
        // Retrieving data from the form
        var values = panel.getValues();
        // 2. Grid (applications)
        var grid = page.win.down('#appGrid');
        var apps = [];
        grid.getStore().each(rec =>
            apps.push({
                name: rec.get('name'),
                enabled: rec.get('enabled')
            }));
        values.selectedApps = apps;
        return values;
    },

    // Helper function to wrap AS.ARC.ajax into a Promise
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
                }
            });
        });
    },
});

// 2. Definition of the main class (Launcher)
Ext.define("AS.ARC.apps.MountFix.main", {
    extend: "AS.ARC._appBase",

    appTag: "MountFix",
    title: "MountFix",
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
            id: "app-MountFix-win"
        });

        mountFixCore.win.on("render", function () {
            app.appOpenNum++;
            app.appIsReady = true;
        });

        mountFixCore.win.on("beforeclose", function () {
            app.appOpenNum--;
            app.appIsReady = true;
            app.appWins = [];
        });

        mountFixCore.win.show();
        this.appWins.push(mountFixCore.win);
    }
});