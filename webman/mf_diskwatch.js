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
