# Engineering Ideas & Architecture Proposals

This document captures architectural analysis, performance bottlenecks, and proposed engineering improvements for future iterations of MountFix.

---

## 1. Optimize `validate.cgi` & Configuration Validation Performance

> **Status (`0.0.0.108`–`0.0.0.115`):** Approaches **A** (single-app `validate(appName)`), **B** (batched single-pass `du -sk` with `awk` human formatting), and **D.1** (non-blocking persistent status bar indicator) are **implemented**. Approaches **C** (two-tier instant state + cached sizes) and **D.2** (optimistic UI updates) remain optional future improvements.

### 1.1 Problem Statement
When MountFix opens or changes configuration states (such as after mounting, unmounting, or switching target volumes), the frontend triggers `validate()` which calls `validate.cgi?act=get&target=/volumeX`.

During this operation, the user interface displays a modal mask (`Validating configuration...`) that blocks interaction for several seconds (typically 5–15 seconds on systems with many installed packages).

### 1.2 Root Cause Analysis
Inspecting `webman/validate.cgi` and `webman/scripts/common.sh` reveals the following pipeline executed for every single package in `/volume1/.@plugins/AppCentral/*`:

1. **Redundant Recursive Traversal on HDD:**
   - Calls `du -sh "$APP_DIR"` (`get_size_human`) to get human-readable source size.
   - Immediately calls `du -sk "$APP_DIR"` (`get_size_kb`) to get numeric size in KB.
   - For applications with massive file counts (e.g. Nextcloud, MariaDB, Photogallery, Docker), each `du` command recursively inspects tens of thousands of inodes on mechanical HDDs, incurring severe disk I/O head seek latency.
2. **Duplicate Recursive Traversal on Target SSD:**
   - If the package folder exists on the target volume, it runs `du -sh "$TARGET_PATH"` followed by `du -sk "$TARGET_PATH"`.
   - Result: Up to **4 distinct recursive `du` process invocations per application** (up to ~100 `du` processes for 25 applications).
3. **Contrast with Fast Mount Checks:**
   - Inode verification (`stat -c %d:%i` in `is_app_bind_mounted`) executes in sub-milliseconds. Recursive `du` disk scanning accounts for >99% of total request execution time.
4. **All-or-Nothing Sweeps:**
   - Even when only a single application state changed (e.g., user clicked *Mount* or *Unmount* on one specific app), the entire list of 20+ packages is rescanned from scratch.
5. **Modal UI Blocking:**
   - The UI enforces `page.maskWindow('Validating configuration...')`, freezing the entire window.

---

### 1.3 Proposed Solutions

#### Approach A: Targeted Single-App Validation (Quick Win)
- **Concept:** `validate.cgi` already supports the parameter `app=PackageName` (`validate.cgi?act=get&target=/volumeX&app=nginx`).
- **Implementation:** Modify `page.validate(appName)` in `webman/mf_actions.js`. When triggered after `mount`, `unmount`, or `sync_back`, pass the active application name.
- **Expected Impact:** Response time drops from ~5–10s to **~50–100ms** for routine user actions.

#### Approach B: Backend Batching & Single-Pass Disk Usage
- **Concept:** Remove duplicate process spawns and calculate sizes in a single pass.
- **Implementation:**
  1. Query `du -sk` once per directory instead of running both `-sh` and `-sk`. Format bytes into human-readable strings (`12.5M`, `1.2G`) on the client side in JavaScript.
  2. Batch source directory queries: Run `du -sk /volume1/.@plugins/AppCentral/*` in one single shell command instead of executing a loop of subshells.
- **Expected Impact:** Cuts total execution time by at least 60–75%.

#### Approach C: Two-Tier Decoupling (Instant State vs. Async Sizes)
- **Concept:** Separate critical actionable state from informative metadata.
- **Implementation:**
  1. **Tier 1 (Instant Path, <50ms):** Query only mount status (`stat`) and target folder existence (`test -d`). Return immediately so the UI enables/disables `Mount`, `Unmount`, and `Sync back` buttons instantly.
  2. **Tier 2 (Background Path / Cache):** Query sizes asynchronously or serve them from a lightweight cache (e.g., `/tmp/mountfix_sizes.cache` with a 10–15 minute TTL), since package installation sizes do not fluctuate every second.
- **Expected Impact:** Eliminates perceived latency entirely when navigating the application.

#### Approach D: Non-Blocking Background UI Refresh & Optimistic Updates
- **Concept:** Keep the UI responsive while background checks run.
- **Implementation:**
  1. Replace `page.maskWindow('Validating configuration...')` with a subtle progress indicator (status bar text or grid header spinner).
  2. Apply **optimistic UI updates**: When `mount.cgi` responds with `{ success: true }`, update the ExtJS grid record in-memory immediately (`record.set('mounted', ...)`), without waiting for disk validation to complete.
- **Expected Impact:** Smooth, modern UX with zero UI freezing.

---

## 2. Safe "Delete Target" Workflow (Future Feature)

### 2.1 Goal
Allow users to reclaim space on the target SSD volume by deleting `<target>/AppCentral/<app>` after reverting an application to `/volume1`, without risking accidental data loss.

### 2.2 Required Safety Guardrails
1. **Strict Pre-Conditions (UI + Server-Side):**
   - App must be **stopped** (verified server-side via `pids_using_paths`).
   - App must **not be bind-mounted** (`!is_app_bind_mounted`) and not listed in `etc/mounts.list`.
   - Target path must match `<targetVolume>/AppCentral/<validatedAppName>` (never parent dirs, never `MountFix`).
2. **Pre-Delete Diff Inspection:**
   - Before confirming deletion, run a read-only comparison (`rsync --dry-run --itemize-changes` / summary of newer or extra files on SSD vs. `/volume1` HDD) and show the result in the confirmation modal.
3. **Recovery-First Prompt:**
   - If differences exist, offer **"Sync back first, then delete"** alongside **"Delete target only"** and **"Cancel"**.
4. **Explicit Irreversible Confirmation:**
   - Clearly warn that deletion cannot be undone and require explicit confirmation (e.g. typing the application name) before invoking the `POST` delete endpoint.

---

## 3. HDD Wakeup & I/O Diagnostics ("What's Waking My HDD?") (Future Feature)

### 3.1 Goal
Help the user identify **which processes or AppCentral packages are still reading/writing to mechanical HDD volumes** (e.g. `/volume1`) so they can either relocate those apps to SSD with MountFix or diagnose why drives fail to enter hibernation/standby.

### 3.2 Technical Approaches & Trade-offs

#### A. Process-Level I/O Collection (Two-Backend Strategy)
Both `/proc/<pid>/io` and `iotop` rely on Linux `CONFIG_TASK_IO_ACCOUNTING` and measure per-process storage I/O (`read_bytes` / `write_bytes`), **not** which disk/volume was hit.

1. **Zero-dependency default — `/proc/<pid>/io` delta sampling:**
   - Take two snapshots of `/proc/[0-9]*/io` (`read_bytes`, `write_bytes`, `cancelled_write_bytes`) separated by a short window (e.g. 3–5 seconds) and compute per-PID deltas in `awk`.
   - **Pros:** Zero external binaries, works out of the box on any ASUSTOR architecture, easy to test and maintain in POSIX `sh` + `awk`.
   - **Cons:** Misses very short-lived processes that start and exit between the two snapshots; does not report `%IO` wait.
2. **Bundled `iotop-static` (`x86-64`) backend:**
   - Because ASUSTOR ADM does not ship `iotop`, bundling a statically compiled `iotop-static` (e.g. `iotop-c` built statically for `x86-64`, matching `CONTROL/config.json`'s `architecture: "x86-64"`) inside the APKG (e.g. `bin/iotop-static`, with optional override via `/opt/sbin/iotop-static`) makes it work out of the box for all users.
   - Invoke it in non-interactive batch mode (e.g. `iotop-static -b -o -P -k -q ...`, adjusted to exact CLI flags of the compiled binary) and parse output with `awk`.
   - **Pros:** Uses Linux Netlink `taskstats` (accurate real-time rates, catches thread/process activity cleanly, reports `%IO` wait), works even when nothing extra is installed on the NAS.
   - **Cons:** Requires maintaining a reproducible build recipe for the static `x86-64` binary (and keeping `/proc/<pid>/io` as a zero-binary fallback).

*(Note: Classic `/proc/sys/vm/block_dump` was removed in Linux 5.15+, so it is not available on ADM 5.x kernels.)*

#### B. Critical Missing Piece: Attributing I/O to HDD vs. SSD
Neither `/proc/<pid>/io` nor `iotop` tells you **which volume** a process touched. To filter out SSD activity and pinpoint HDD culprits:
1. **Disk-level verification (zero wakeup):**
   - Check `/sys/block/<dev>/stat` (or `/proc/diskstats`) sector read/write deltas for the HDD RAID/member devices during the same sampling window to confirm physical HDD I/O actually occurred.
   - Check drive power state via `hdparm -C /dev/sdX` (or `smartctl -i -n standby`) — safe to run without waking sleeping drives.
2. **Per-PID device correlation via `st_dev`:**
   - Resolve the device ID of `/volume1` (`stat -c %d /volume1`).
   - For each PID with non-zero I/O delta, inspect `/proc/<pid>/fd/*` and `/proc/<pid>/cwd` using `stat -L -c %d`.
   - **Key advantage with MountFix:** Files inside a bind-mounted AppCentral app report the **SSD's `st_dev`**, not `/volume1`'s `st_dev`, so relocated apps are automatically separated from real HDD access.
3. **AppCentral mapping:**
   - Match active HDD paths (`/volume1/.@plugins/AppCentral/<app>/...`) or process `cmdline` against installed AppCentral packages to highlight: *"This process belongs to `<app>`, which is currently on HDD — consider relocating it to SSD."*

### 3.3 Sampling Modes, Prototype Scripts & Safety Constraints
- **Reference prototypes:** Initial non-root shell observers are archived in `docs/prototypes/diskwatch/` (`diskwatch.sh`, `diskwatch2.sh`, `diskwatch3.sh`) — not packaged into the APKG (`build.sh` only packs `CONTROL/`, `webman/`, `etc/`).
  - **What to carry over:** Event-driven logging on `/proc/diskstats` changes, writing strictly to `tmpfs` (`/tmp`) so the observer never triggers HDD writes.
  - **What to improve when integrating into MountFix (runs as `root`):**
    1. Replace CPU-burn guessing (`/proc/*/stat`) with real per-PID I/O deltas (`/proc/[0-9]*/io` `read_bytes`/`write_bytes` or bundled `iotop-static`), keeping `D`-state detection as an extra signal.
    2. Dynamically detect rotational HDD block devices (`rotational == 1`) and their partitions/`md*` instead of hardcoding `sd[a-c][24]`.
    3. Initialize `prevhdd` *before* the loop so the first sample does not emit a false `HDD-ACTIVITY` event on idle/sleeping drives.
    4. Compute and store **deltas** (`+R / +W`) rather than raw cumulative boot counters.
- **Supported durations & adaptive intervals:**
  - Preset durations: `5s`, `30s`, `60s`, `300s` (5m), `600s` (10m), `1200s` (20m).
  - Short runs (`5 / 30 / 60s`): 1s sampling interval; longer background runs (`300 / 600 / 1200s`): 3s sampling interval with lock/PID/status JSON in `/tmp` (`tmpfs`), Start/Stop controls, and auto-stop timer.
- **UI Presentation:** A lightweight "HDD Activity Monitor" modal or tab showing:
  - Controls (`5s / 30s / 60s / 5m / 10m / 20m`, Start/Stop, progress `elapsed / total`), HDD power state (`standby` / `active/idle`), and total physical HDD read/write delta during the capture.
  - **Tab 1 — Summary (Top Culprits):** Aggregated per process (`Process / AppCentral`, `HDD Hits`, `Read/Write KB`, `D-state`, `Last Seen`, `Target Volume`, and a *"Still on HDD — can relocate"* badge for unmounted AppCentral packages).
  - **Tab 2 — Timeline:** Chronological list of actual HDD activity events (`HH:MM:SS | dev (+R/+W) | active processes`).
  - Badge indicating which collector ran (`iotop-static` vs `/proc/io`).
