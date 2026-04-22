# MountFix for ASUSTOR ADM

A custom ADM plugin designed to migrate default AppCentral applications to alternate volumes (e.g., secondary SSD storage) using `mount --bind`.

# Key Features:

Storage Optimization: Move heavy apps (Docker, PhotoGallery, etc.) from Volume 1 to any other volume without breaking ADM integration.

ADM Integrated UI: Native Look & Feel interface built with ExtJS.

Boot-safe: Includes an init script (S01mountfix) to ensure mounts are established before apps start.

Smart Cleanup: Graceful unmounting with process-check logic to prevent filesystem lockups during shutdown.

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

At the current development stage (version 0.0.0.62), MountFix is a partially implemented APKG package for ASUSTOR ADM. The project uses the ADM plugin architecture to integrate with the NAS system.

## System Architecture
- **APKG Package**: Consists of CONTROL/ (metadata, installation scripts), webman/ (web interface), etc/ (configuration).
- **Language**: Mainly Bash (scripts), JavaScript (UI ExtJS), JSON (configuration).
- **Dependencies**: Requires entware (opkg) to install bash, jq.

## Application Migration Mechanism
1. **Configuration**: The `etc/mountfix.conf` file contains JSON with `targetVolume` (e.g., "/volume2") and `selectedApps` (array of objects with `name` and `enabled`).
2. **Application Detection**: `webman/scripts/common.sh` contains the `get_installed_apps_json()` function, which parses `/usr/builtin/etc/appcentral/installed.json` using jq to get the list of installed applications.
3. **Validation**: `validate.cgi` checks the sizes of source folders (`/volume1/.@plugins/AppCentral/APP`) and target folders (`TARGET/AppCentral/APP`), and the mounting status by comparing inodes (`check_app_mount_json`).
4. **Migration**: `scripts/migrate.sh` copies application folders from source to target. `setup.cgi` (incomplete) should handle the "setup_app" action.
5. **Mounting**: `CONTROL/start-stop.sh` (partially commented out) executes `mount --bind TARGET/AppCentral/APP /volume1/.@plugins/AppCentral/APP` so the system sees the data in the original location. Additionally, sets sysctl for memory optimization (vm.swappiness=1, vm.vfs_cache_pressure=10, vm.dirty_writeback_centisecs=6000).
6. **Init Script**: S01mountfix ensures mounts are performed before applications start.
7. **UI**: `mountfix.js` (ExtJS) displays a combo for volume selection (with SSD/HDD info via `get_volume_rotational`) and a grid of applications with status, sizes, mounting.

## CGI API
- `apps.cgi?act=get`: Returns the list of applications in JSON.
- `config.cgi?act=get`: Returns config, apps, volumes.
- `config.cgi?act=set`: Saves config from POST JSON.
- `validate.cgi?act=get&target=VOL&app=NAME`: Validates the application.
- `setup.cgi?act=setup_app`: (Incomplete) For application migration.

## Development Status
- Mounting code in `start-stop.sh` is commented out – likely requires testing and completion.
- `setup.cgi` requires implementation of migration logic.
- Lack of full integration with AppCentral for automatic stopping/starting of applications during migration.
- Testing on a real ASUSTOR NAS required for validation.

For further development: Implement full API, test on various RAID/SSD configurations, add logging and error handling.