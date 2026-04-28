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
            fields: ['name', 'selected', 'enabled', 'status', 'sourceSize', 'targetSize', 'mounted'],
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
                            viewConfig: {
                                getRowClass: function (record) {
                                    return record.get('enabled') ? 'x-item-disabled' : '';
                                },
                            },
                            selModel: {
                                allowDeserialization: true,
                                listeners: {
                                    beforeselect: function (sm, record) {
                                        if (record.get('enabled')) {
                                            return false;
                                        }
                                    },
                                    selectionchange: function (sm, selected) {
                                        fn.selectedApp = selected.length > 0 ? selected[0] : null;
                                        fn.updateActionsUI();
                                    },
                                },
                            },
                            columns: [
                                {
                                    xtype: 'checkcolumn',
                                    text: 'Mount',
                                    dataIndex: 'selected',
                                    width: 60,
                                    resizable: false,
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
                                    width: 100,
                                    renderer: function (v, m, row) {
                                        const {mounted, enabled} = row.data;
                                        const val = mounted ? 'Mounted' : enabled ? 'Not ready' : 'Ready';
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
                    title: 'Misc Options',
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
                                    text: 'Sync back',
                                    itemId: 'btnSyncBack',
                                    handler: function () {
                                        // sync back should call backend to copy back data from the mounted volume/folder to the original location,
                                        // this is needed when user wants to revert the changes but has some data written to the mounted volume that they want to keep.
                                        // After successful sync back user can uncheck the "Fix" checkbox and click Apply to unmount the volume and revert changes
                                        // it could also be done periodically on each app change to keep data in sync, but for now let's keep it manual to avoid unnecessary writes and potential performance impact.
                                        console.log('sync back');
                                    },
                                },
                            ],
                        },
                        {
                            xtype: 'displayfield',
                            fieldLabel: 'Version',
                            value: '0.0.0.74',
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
