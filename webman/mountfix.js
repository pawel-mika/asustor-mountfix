/**
 * MountFix Application for ASUSTOR ADM
 */

// 1. Definition of the application core (UI and Logic)
Ext.define("AS.ARC.apps.MountFix.core", {
  extend: "Ext.util.Observable",

  maskStack: [],

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
      fields: [
        "name",
        "selected",
        "enabled",
        "status",
        "sourceSize",
        "targetSize",
        "mounted",
      ],
      data: [],
    });

    // Main form panel (window base)
    var mainPanel = Ext.create("AS.ARC.formBase", {
      itemId: "mainPanel",
      cls: "as-page-panel",
      border: false,
      // Change layout to vbox to manage vertical space
      layout: {
        type: "vbox",
        align: "stretch", // Makes items take full width
      },
      bodyPadding: "8 16",
      items: [
        // --- SECTION 1: TARGET ---
        {
          xtype: "fieldset",
          title: "Target Volume",
          collapsible: false,
          layout: "anchor",
          items: [
            {
              anchor: "100%",
              xtype: "combo",
              fieldLabel: "Select Volume",
              name: "targetVolume",
              store: {
                fields: ["volume", "mountPoint", "freeSpace", "totalSpace", "usedPercent", "isSSD"],
                data: [],
              },
              queryMode: "local",
              displayField: "volume",
              valueField: "volume",
              editable: false,
              triggerAction: "all",
              tpl: Ext.create(
                "Ext.XTemplate",
                '<tpl for=".">',
                '<div class="x-boundlist-item {[!values.isSSD ? "x-item-disabled" : ""]}">',
                "{volume} ({mountPoint}) - {freeSpace} of {totalSpace} free, ({usedPercent} used) ",
                "[",
                '<tpl if="isSSD">SSD</tpl>',
                '<tpl if="!isSSD">HDD</tpl>',
                "]",
                "</div>",
                "</tpl>",
              ),
              listeners: {
                beforeselect: function (combo, record) {
                  return record.get("isSSD");
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
          xtype: "fieldset",
          title: "Sources & Applications",
          flex: 1,
          layout: "fit",
          margin: "8 0",
          items: [
            {
              xtype: "grid",
              itemId: "appGrid",
              store: appStore,
              border: true,
              columnLines: true,
              scrollable: true,
              padding: "0 0 30 0",
              viewConfig: {
                getRowClass: function (record) {
                  return record.get("enabled") ? "row-disabled" : "";
                },
              },
              selModel: {
                allowDeserialization: true,
                listeners: {
                  beforeselect: function (sm, record) {
                    if (record.get("enabled")) {
                      return false;
                    }
                  },
                },
              },
              columns: [
                {
                  xtype: "checkcolumn",
                  text: "Fix",
                  dataIndex: "selected",
                  width: 40,
                  resizable: false,
                },
                {
                  xtype: "checkcolumn",
                  text: "Enabled",
                  dataIndex: "enabled",
                  width: 60,
                  resizable: false,
                  processEvent: function () {
                    return false;
                  },
                  renderer: function (value) {
                    var color = value ? "green" : "gray";
                    var text = value ? "Running" : "Stopped";
                    return (
                      '<span style="color:' +
                      color +
                      '; font-weight:light; font-size:9px;">● ' +
                      text +
                      "</span>"
                    );
                  },
                },
                {
                  text: "Application Name",
                  dataIndex: "name",
                  flex: 1,
                  menuDisabled: true,
                },
                {
                  text: "Current Status",
                  dataIndex: "status",
                  width: 100,
                  renderer: function (val) {
                    var color = val === "Ready" ? "green" : "gray";
                    return (
                      '<span style="color:' + color + ';">' + val + "</span>"
                    );
                  },
                },
                {
                  text: "Source Size",
                  dataIndex: "sourceSize",
                  width: 80,
                  menuDisabled: true,
                },
                {
                  text: "Target Size",
                  dataIndex: "targetSize",
                  width: 80,
                  menuDisabled: true,
                },
                {
                  text: "Mounted on",
                  dataIndex: "mounted",
                  flex: 1,
                  menuDisabled: true,
                  renderer: (val) => val && val.target,
                },
              ],
            },
          ],
        },

        // --- SECTION 3: MISC ---
        {
          xtype: "fieldset",
          title: "Misc Options",
          items: [
            {
              xtype: "checkbox",
              boxLabel: "Auto-repair mount points on system boot",
              name: "autoRepair",
              checked: true,
            },
            {
              xtype: "displayfield",
              fieldLabel: "Engine Version",
              value: "v1.2.0 (Stable)",
            },
          ],
        },
      ],

      // --- PROFESSIONAL FOOTER (Compatible with miniDLNA/ADM) ---
      fbar: [
        {
          xtype: "container",
          itemId: "statusInfo",
          html: "",
          style: "color: #333; font-size: 12px;",
          margin: "0 16 0 16",
        },
        { xtype: "tbfill" }, // Filler moves buttons to the right
        {
          xtype: "button",
          text: "Apply",
          itemId: "btnApply",
          width: 85,
          handler: function () {
            fn.saveConfig();
          },
        },
        {
          xtype: "button",
          text: "Cancel",
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
      title: "MountFix",
      width: 480,
      height: 640,
      layout: "fit",
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

  getSelectedVolume: function () {
    return this.win.down("combo[name=targetVolume]")?.getValue() ?? null;
  },

  updateStatus: function (message, isError) {
    var statusCont = this.win.down("#statusInfo");
    var color = isError ? "#cc0000" : "#007dff";
    var icon = isError ? "alert.png" : "common-icon_16X16_status_tip_ok.png";
    statusCont.update(
      '<img src="resources/images/icons/common_16x16/' +
        icon +
        '" style="vertical-align:middle; margin-right:5px;">' +
        message,
    );
    statusCont.el.setStyle("color", color);
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
    var actionMsg = "Loading configuration...";
    window.qq = this;
    page.maskWindow(actionMsg);

    AS.ARC.ajax({
      url: AS.ARC.util.getApiUrlWithSid(page.configApiUrl, { act: "get" }),
      method: "GET",
      success: function (json) {
        console.log("Config loaded:", json);
        page.cgiConfig = json; // Store config for later use
        page.setConfig(page.cgiConfig); // Update UI with loaded config
        page.validate();
        page.unmaskWindow(actionMsg);
      },
      failure: function () {
        console.error("Failed to load config");
        page.unmaskWindow(actionMsg);
      },
    });
  },

  saveConfig: function () {
    var page = this;
    var actionMsg = "Saving configuration...";
    page.maskWindow(actionMsg);

    AS.ARC.ajax({
      url: AS.ARC.util.getApiUrlWithSid(page.configApiUrl, { act: "set" }),
      params: Ext.encode(page.getConfig()),
      success: function (json) {
        page.updateStatus("Settings applied successfully", false);
        page.unmaskWindow(actionMsg);
      },
      failure: function (json) {
        page.updateStatus("Error: Unable to save settings", true);
        page.unmaskWindow(actionMsg);
      },
    });
  },

  validate: function () {
    var page = this;
    var target = page.getSelectedVolume();
    var actionMsg = "Validating configuration...";
    page.maskWindow(actionMsg);

    AS.ARC.ajax({
      url: AS.ARC.util.getApiUrlWithSid(page.validateApiUrl, {
        act: "get",
        target,
      }),
      method: "GET",
      success: function (json) {
        console.log("validated:", json);
        if (json.success && json.apps) {
          var grid = page.win.down("#appGrid");
          if (grid) {
            var store = grid.getStore();
            json.apps.forEach(function (app) {
              var record = store.findRecord(
                "name",
                app.name,
                0,
                false,
                false,
                true,
              );
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
        console.error("Failed to load validation data");
        page.unmaskWindow(actionMsg);
      },
    });
  },

  setConfig: function (newConfig) {
    var page = this;
    var selectedApps =
      newConfig.config?.selectedApps?.map(({ name }) => name) || [];
    var mappedApps = (newConfig.apps || []).map(({ package, enabled }) => ({
      name: package,
      selected: selectedApps.includes(package),
      enabled,
      status: "...",
    }));
    var grid = page.win.down("#appGrid");
    if (grid) {
      grid.getStore().loadData(mappedApps);
    }
    if (newConfig.volumes) {
      var combo = page.win.down("combo[name=targetVolume]");
      if (combo) {
        combo.getStore().loadData(newConfig.volumes);
        combo.setValue(newConfig.config.targetVolume);
      }
    }
  },

  getConfig: function () {
    var page = this;
    var panel = page.win.down("#mainPanel");
    // Retrieving data from the form
    var values = panel.getValues();
    // 2. Grid (applications)
    var grid = page.win.down("#appGrid");
    values.selectedApps = grid
      .getStore()
      .data.items.map((r) => r.data.selected && { name: r.get("name") })
      .filter(Boolean);
    return values;
  },

  maskWindow: function (message) {
    message = message || "Working...";
    this.maskStack.push(message);
    this.win &&
      this.win.el &&
      this.win.el.mask(this.maskStack[this.maskStack.length - 1]);
  },

  unmaskWindow: function (message) {
    if (message) {
      Ext.Array.remove(this.maskStack, message);
    } else {
      this.maskStack.pop();
    }

    if (this.maskStack.length > 0) {
      this.win &&
        this.win.el &&
        this.win.el.mask(this.maskStack[this.maskStack.length - 1]);
    } else {
      this.win && this.win.el && this.win.el.unmask();
    }
  },

  // Helper function to wrap AS.ARC.ajax into a Promise
  requestConfig: function (params) {
    var me = this;
    return new Promise(function (resolve, reject) {
      AS.ARC.ajax({
        url: AS.ARC.util.getApiUrlWithSid(me.apiUrl, params),
        method: "GET",
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
      id: "app-MountFix-win",
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
  },
});
