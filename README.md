# MountFix for ASUSTOR ADM

A custom ADM plugin designed to migrate default AppCentral applications to alternate volumes (e.g., secondary SSD storage) using `mount --bind`.

# Key Features:

Storage Optimization: Move heavy apps (Docker, PhotoGallery, etc.) from Volume 1 to any other volume without breaking ADM integration.

ADM Integrated UI: Native Look & Feel interface built with ExtJS.

Boot-safe: Installs an ADM init script (`S02MountFix` / `K02MountFix`) that establishes bind mounts before relocated apps start (`jq`-free boot path via `etc/mounts.list`).

Smart Cleanup: Fast non-lazy unmounting with per-path `/proc` holder detection, persistent logging (`var/mountfix.log`), and shutdown-aware cleanup so ADM `stormand` always unmounts volumes cleanly.

# Prerequisities (TBD)

* Installed entware(opkg) - MountFix will install required commands/packages (bash, jq) during install

# 🛑 Disclaimer & Responsibility
Use this software at your own risk.

This plugin performs low-level system operations on your Asustor NAS, including:

Moving application data between volumes.

- Modifying system mount points using `mount --bind`.
- Altering Linux kernel parameters (`sysctl`).
- By using this tool, you acknowledge that:

Data Safety: You are responsible for your own data. Always maintain a current backup of your critical files and app configurations before using this tool.

No Warranty: This software is provided "as is", without any warranty. The author is not liable for any data loss, system instability, hardware damage, or service downtime.

ADM Updates: Future Asustor ADM updates may change how the system handles volumes or apps, which could break this plugin's functionality.

Manual Intervention: While the plugin automates the process, it is your responsibility to ensure that the target SSD volume has sufficient space and is healthy.

# 📜 License
This project is licensed under the MIT License. This means you are free to use, modify, and distribute the software, provided that the copyright notice and this permission notice are included in all copies.

# Pro-tips for a Safe Experience:
Stop before you move: Always stop the targeted application in AppCentral before applying a "fix" to ensure data integrity during migration.

Monitor Logs: If an app behaves unexpectedly after a move, check the status column and ensure the bind mount is active.

Test small: Start by moving a less critical app to verify everything works as expected in your specific environment.

# Description for End Users

MountFix is a tool for ASUSTOR NAS device owners that allows you to move selected AppCentral applications (such as Docker, PhotoGallery, or other heavy applications) from the default Volume 1 to another volume, for example, an additional SSD drive. The goal is to improve system performance, as applications run faster on SSD than on traditional HDD drives.

## How does it work for you?
1. **Installation**: Install the MountFix package through AppCentral in ADM (Asustor Data Master).
2. **Configuration**: In the MountFix interface, select the target volume (e.g., /volume2 on SSD) and check the applications you want to move.
3. **Migration**: The tool will automatically copy the application data to the new volume and configure a "bind mount", which means the system still sees the application in the original location (/volume1/.@plugins/AppCentral/), but the data is physically on the SSD.
4. **Launch**: After restarting the system, applications will run from the new location, without losing functionality in ADM.

This way, your applications will be faster, and the main volume will be less loaded. Remember to back up your data before migration!

# Mechanism Description for Developers

For an in-depth technical breakdown of IPC, background transfer execution, polling mechanisms, and safety guardrails, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

At the current development stage, MountFix uses the ADM plugin architecture to integrate with the NAS system.


## System Architecture
- **APKG Package**: Consists of CONTROL/ (metadata, installation scripts), webman/ (web interface), etc/ (configuration).
- **Language**: Mainly Bash (scripts), JavaScript (UI ExtJS), JSON (configuration).
- **Dependencies**: Requires entware (opkg) to install bash, jq.

## Application Migration & Boot Mechanism
1. **Configuration**: `etc/mountfix.conf` stores the UI configuration (`targetVolume` and `selectedApps`), while `etc/mounts.list` provides a pre-validated, `jq`-free `SRC:TGT` list for boot/shutdown scripts (kept in sync on config save and package upgrades).
2. **Application Detection**: `webman/scripts/common.sh` (`get_installed_apps_json()`) parses `/usr/builtin/etc/appcentral/installed.json` to list installed AppCentral packages (excluding `MountFix`). Shared helpers live in `CONTROL/lib.sh`.
3. **Validation**: `validate.cgi` checks source (`/volume1/.@plugins/AppCentral/APP`) and target (`TARGET/AppCentral/APP`) directory sizes and verifies active bind mounts via device/inode comparison (`stat -c %d:%i`).
4. **Migration & Sync-Back**: `migrate.cgi` runs non-blocking, detached background `rsync` transfers (`-aH --numeric-ids` plus auto-detected `-A`/`-X`/`--outbuf=L`, with `--delete` mirror mode for sync-back and forced re-copy) protected by an atomic mutex lock, server-side busy-process guard (`pids_using_paths`), and explicit `DONE`/`ERROR` status reporting.
5. **Mounting & Shutdown**: `CONTROL/start-stop.sh` (`S02MountFix` / `K02MountFix`) binds `TARGET/AppCentral/APP` onto `/volume1/.@plugins/AppCentral/APP` at boot, applies `sysctl` memory/VFS tuning on `start`, and safely unmounts in reverse order on `stop` (skipping busy apps during runtime upgrades and cleaning up lingering holders only on real ADM `REBOOT`/`SHUTDOWN`).
6. **Observability**: Logs all boot/shutdown operations to `var/mountfix.log` and emits warnings to the ADM System Log (`/usr/sbin/syslog --level 1`).
7. **UI**: `mountfix.js` (ExtJS) provides target volume selection (SSD/HDD detection) and per-application copy, mount, unmount, and sync-back actions.

## CGI API
All CGIs require a valid ADM **administrator** session (`sid` query parameter, verified through ADM's `admin.cgi`); otherwise they return `{"success": false, "error": "Unauthorized: ..."}`.

- `apps.cgi?act=get`: Returns installed applications in JSON (`MountFix` itself is excluded).
- `config.cgi?act=get`: Returns current configuration, apps, volumes, and package version.
- `config.cgi?act=set`: Saves configuration from POST JSON and updates `etc/mounts.list`.
- `validate.cgi?act=get&target=VOL[&app=NAME]`: Returns mount status and disk usage per app.
- `mount.cgi?act=mount|unmount&app=NAME&target=VOL`: Mounts or unmounts an application directory.
- `migrate.cgi?act=migrate|sync_back|status`: Starts or polls background data migration / sync-back.

## Documentation & Roadmap
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): Internal IPC, transfer flow, and boot/shutdown lifecycle.
- [docs/TECHNICAL-REVIEW.md](docs/TECHNICAL-REVIEW.md): Full security/reliability audit, Stage 1 production verification (ADM 5.1.5), and Stage 2 roadmap.
- [IDEAS.md](IDEAS.md): Performance optimization proposals for `validate.cgi`.