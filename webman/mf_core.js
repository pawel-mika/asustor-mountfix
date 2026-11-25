/**
 * MountFix Core
 */
Ext.define('AS.ARC.apps.MountFix.core', {
    extend: 'Ext.util.Observable',
    mixins: ['AS.ARC.apps.MountFix.Actions'],

    constructor: function (config) {
        Ext.apply(this, config);
        this.maskStack = [];
        this._pollTimer = null;
        this._pollActive = false;
        this._statusFadeTimer = null;
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
                            style: 'color: #888; font-size: 11px;',
                        },
                        { xtype: 'tbfill' },
                        {
                            xtype: 'container',
                            itemId: 'statusInfo',
                            html: '',
                            style: 'color: #333; font-size: 12px;',
                            margin: '0 12 0 8',
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

        // Creating window through ADM desktop
        this.win = this.desktop.createWindow({
            app: fn.app,
            id: fn.id,
            title: 'MountFix',
            width: winWidth,
            height: winHeight,
            layout: 'fit',
            taskIcon: '../apps/MountFix/images/icon-app-task.png',
            tools: [
                {
                    type: 'help',
                    tooltip: 'MountFix Quick Guide',
                    handler: function () {
                        fn.showHelpDialog();
                    },
                },
            ],
            items: [mainPanel],
            listeners: {
                afterrender: function (win) {
                    // Initialization of ADM scrollbar (PerfectScrollbar)
                    if (window.Ps) {
                        Ps.initialize(win.body.dom);
                    }
                    fn.loadConfig(); // Load initial config
                },
                beforeclose: function () {
                    fn.stopMigrationMonitor();
                    if (fn._statusFadeTimer) {
                        clearTimeout(fn._statusFadeTimer);
                        fn._statusFadeTimer = null;
                    }
                },
            },
        });
    },
});
