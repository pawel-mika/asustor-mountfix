/**
 * MountFix Application for ASUSTOR ADM
 * Full Integrated Version with Professional Footer and Form Panels
 */

// 1. Definition of the application core (UI and Logic)
Ext.define("AS.ARC.apps.MountFix.core", {
    extend: "Ext.util.Observable",

    // Paths to API (adjust if folder name is different)
    apiUrl: AS.ARC.util.getUserAppsPath() + "MountFix/" + "mountfix.cgi",

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
            fields: ["name", "enabled", "status"],
            data: []
        });

        this.loadConfig(); // Load initial config

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
                        name: 'target_volume',
                        store: [],
                        value: '',
                        queryMode: 'local',
                        editable: false,
                        triggerAction: 'all'
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
                            }
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
                            name: 'auto_repair',
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
                    margin: '0 0 0 10'
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
            width: 580,
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

    // Notification function in footer (fadeIn/fadeOut effect)
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

    // Example of loading data from your CGI
    loadConfig: function () {
        var page = this;

        AS.ARC.ajax({
            url: AS.ARC.util.getApiUrlWithSid(page.apiUrl, { act: "get" }),
            method: "GET",
            success: function (json) {
                console.log("Config loaded:", json);
                page.cgiConfig = json; // Store config for later use
                var mappedApps = (page.cgiConfig.allApps || []).map(name => ({ name, enabled: false, status: 'Ready' }));
                var grid = page.win.down('#appGrid');
                if (grid) {
                    grid.getStore().loadData(mappedApps);
                }
                if (page.cgiConfig.volumes) {
                    var combo = page.win.down('combo[name=target_volume]');
                    if (combo) {
                        var volData = json.volumes.map(function (v) { return [v, v]; });
                        combo.getStore().loadData(volData);
                    }
                }
            },
            failure: function () {
                console.error("Failed to load config");
            },
        });
    },

    saveConfig: function () {
        var fn = this;
        var panel = fn.win.down('#mainPanel');

        // Masking window during save
        fn.win.el.mask("Saving changes...");

        // Retrieving data from the form
        var values = panel.getValues();

        // Simulation of sending to CGI
        AS.ARC.ajax({
            url: fn.apiUrl,
            params: {
                act: 'save',
                data: Ext.encode(values)
            },
            success: function (json) {
                fn.win.el.unmask();
                fn.updateStatus("Settings applied successfully", false);
            },
            failure: function (json) {
                fn.win.el.unmask();
                fn.updateStatus("Error: Unable to save settings", true);
            }
        });
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