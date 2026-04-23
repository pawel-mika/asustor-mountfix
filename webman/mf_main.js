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
