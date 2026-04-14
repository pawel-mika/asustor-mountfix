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