# Engineering Ideas & Architecture Proposals

This document captures architectural analysis, performance bottlenecks, and proposed engineering improvements for future iterations of MountFix.

---

## 1. Optimize `validate.cgi` & Configuration Validation Performance

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
