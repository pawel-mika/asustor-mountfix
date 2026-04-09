# MountFix for ASUSTOR ADM

A custom ADM plugin designed to migrate default AppCentral applications to alternate volumes (e.g., secondary SSD storage) using mount --bind.

# Key Features:

Storage Optimization: Move heavy apps (Docker, PhotoGallery, etc.) from Volume 1 to any other volume without breaking ADM integration.

ADM Integrated UI: Native Look & Feel interface built with ExtJS.

Boot-safe: Includes an init script (S01mountfix) to ensure mounts are established before apps start.

Smart Cleanup: Graceful unmounting with process-check logic to prevent filesystem lockups during shutdown.

## prerequisities (TBD)

* installed entware(opkg) with following packages:
  - jq