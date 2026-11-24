# MountFix — Technical Review, Findings & Proposed Fixes

| | |
|---|---|
| **Date** | 2026-11-19 (updated 2026-11-24) |
| **Reviewed revision** | Initial audit on `96ac956` (`0.0.0.102`); Stage 1 implemented & verified on NAS in `0.0.0.103`–`0.0.0.105`; Stage 2 Branch 1 implemented in `0.0.0.106` (installed on NAS, see §8); Stage 2 Branch 2 implemented in `0.0.0.107` (`fix/transfer-engine`, see §9) |
| **Scope** | Whole repository: `CONTROL/`, `webman/` (CGI + shell library + ExtJS UI), `build.sh` / `buildJs.sh`, `tests/`, `etc/` |
| **Status** | **Stage 1 complete & production-verified** (`F1`, `F2`, `F11` start-only `sysctl`, persistent logging, ADM syslog warnings, shutdown-aware cleanup). **Stage 2 Branch 1 implemented (`0.0.0.106`, installed on NAS):** `F5`, `F6`, `F7`, `F13`, `F14` and the shell items of `F17` (see §8). **Stage 2 Branch 2 implemented (`0.0.0.107`, `fix/transfer-engine`):** `F4`, `F8`, `F12` (see §9). **Remaining:** `F3`, `F9`, `F10`, `F11` (UI option), `F15`, `F16` and the JS items of `F17`. |

---

## 0. How to use this document (for the implementing agent)

1. Branch off `master` (`0.0.0.105`+, which matches what is deployed on the NAS) following the **4-branch Stage 2 execution plan in §4.1**. Do not commit directly to `master` without verification.
2. Group overlapping changes into the **thematic branches and atomic commits defined in §4.1** rather than creating 15 separate branches (most remaining findings touch the same `webman/scripts/common.sh` and `webman/mf_actions.js` files).
3. Read section 2 (*Context*) and section 7 (*Field Verification*) first — several fixes depend on facts about ADM verified on production hardware.
4. Do **not** test destructive behaviour (stop/unmount/kill paths) on the real NAS without the user being present. Unit-test locally first (see the test ideas in each finding).
5. Keep the existing style: POSIX `sh` (BusyBox `ash` on the NAS — no bashisms in `CONTROL/` or `webman/*.cgi`), ExtJS 4-style `Ext.define` in the UI, 4-space indent, Prettier config in `.prettierrc`.

---

## 1. What MountFix is (assumptions the code relies on)

ASUSTOR ADM always installs AppCentral packages to `/volume1/.@plugins/AppCentral/<pkg>` — the user cannot choose a volume. When `/volume1` is an HDD, heavy apps (Docker, Photo Gallery, Download Center…) are slow.

MountFix relocates selected packages to a faster volume (SSD/NVMe) **transparently to ADM**:

1. **Copy** — `rsync` `/volume1/.@plugins/AppCentral/<pkg>` → `/volumeX/AppCentral/<pkg>`.
2. **Bind-mount** — `mount --bind /volumeX/AppCentral/<pkg> /volume1/.@plugins/AppCentral/<pkg>`. ADM and the app keep using their usual path; data physically lives on the SSD.
3. **Boot integration** — `CONTROL/start-stop.sh` (installed by ADM as `/usr/local/etc/init.d/S02MountFix` / `K02MountFix`) re-creates the bind mounts at boot *before* apps start and removes them at shutdown *after* apps stop.

Design assumptions:

- Target volume must be an SSD (UI blocks HDD volumes in the combo box).
- The original HDD copy is **kept** under the mount as a fallback; *Sync back* copies newer data SSD → HDD (before uninstall / disk changes).
- Copy / mount / unmount / sync-back must only happen while the app is **stopped**.
- ADM must not notice anything (bind mount rather than symlinks or app reconfiguration).
- Runtime tools (`jq`, `bash`) come from **Entware** (`depends: ["entware"]`).
- Side goal: `sysctl` tuning to reduce disk activity (swap, VFS cache, dirty writeback).

---

## 2. Context — facts verified on the target NAS

These were checked read-only on the production NAS (ADM 5.x, x86-64) during the review:

| Fact | Consequence |
|---|---|
| `fuser` is **BusyBox** (`/usr/bin/fuser -> /bin/busybox`). `-m` means "all processes using the **filesystem** that contains this path". | `fuser -m <dir>` is not per-directory — see F1. |
| Init order: `S02MountFix`, `S20download-center`, `S50minidlna`, **`S52entware`**, `S65docker-ce`. Stop order (ADM runs `K*` with `sort -r`): `K80…`, `K52entware`, `K35docker-ce`, …, **`K02MountFix`**. | MountFix starts *before* Entware and stops *after* Docker. |
| `jq` exists **only** at `/usr/local/AppCentral/entware/opt/bin/jq`. Not on the default `PATH`; `/opt/bin` symlink did not exist at review time. | Boot-time config parsing cannot rely on `jq` — see F2. |
| `entware` itself is one of the bind-mounted (relocated) packages. | MountFix's own dependency lives on a volume MountFix mounts. |
| `docker-ce` has **nested mounts** under its plugin dir (`docker-ce/docker_lib`, `docker_lib/overlay2/*/merged`). | Plain `umount` of `docker-ce` fails while Docker runs; that is desirable. |
| Installed package on NAS == this branch byte-for-byte (except `CONTROL/icon-disable.png`, which ADM rewrites). | This branch is the source of truth. |

The CGIs could not be reached without an ADM session during the review (404 on the guessed path), so **whether ADM enforces authentication for `webman/*.cgi` is unverified** — see F5.

---

## 3. Findings (priority order)

Severity: 🔴 critical (data loss / outage possible) · 🟠 important · 🟡 cleanup.

### F1 🔴 `start-stop.sh stop` can SIGKILL every process on a whole volume

**Where:** `CONTROL/start-stop.sh:59-85`

```sh
if ! fuser -m "$TGT" ...        # line 65
fuser -k -m "$TGT" ...          # line 76
umount -l "$TGT" ...            # line 83
```

**Problem**

- BusyBox `fuser -m $TGT` reports every process using the *filesystem* containing `$TGT`, not just the app directory. For a mounted app this is the whole target volume (e.g. `/volume2`); for an app that is listed in config but **not** mounted, `$TGT` is on `/volume1` → the whole system volume.
- The wait loop runs *before* checking `is_mounted`, i.e. also for entries that are not mounted.
- After 20 s it runs `fuser -k -m` → **SIGKILL to every process on that filesystem**.
- It then does `umount -l` (lazy), which detaches the mount even if processes still have it open — running apps keep writing to the SSD copy while newly started processes see the stale HDD copy.
- The 20 s wait is per app, sequential.

**Impact**

`stop` is executed not only at NAS shutdown (where `K02` runs after all apps, so it is mostly harmless), but also when MountFix is **stopped, disabled, upgraded or restarted from AppCentral** while Docker and other apps are running. In that case the script kills Docker, other relocated apps and potentially ADM services, then lazily unmounts their data.

**Proposed fix**

Principle: **unmount only what nobody uses; never kill; never lazy-unmount.** This single rule is correct for both situations (shutdown: apps already stopped → unmount succeeds; manual stop/upgrade: apps running → mounts are left alone, the following `start` reports "Already mounted").

0. **Back up the current script first:** copy `CONTROL/start-stop.sh` to `CONTROL/start-stop.sh.old` (unchanged, in the same commit as the rewrite, so the diff is reviewable and the old behaviour can be restored quickly).
   - Make sure the `.old` file is **not packaged**: `build.sh` copies the whole `CONTROL/` directory into the APK. Either exclude `*.old` in `build.sh` (e.g. `rm -f "$TEMP_FOLDER"/CONTROL/*.old` after the copy) or keep the backup outside `CONTROL/` (e.g. `docs/legacy/start-stop.sh.old`). Preferred: keep it next to the original as requested and add the exclusion in `build.sh`.
   - `.gitignore` ignores `*.bak*`, so do **not** use a `.bak` suffix — it would not be committed.
   - Before any manual test on the NAS, also back up the installed init scripts: `/usr/local/etc/init.d/S02MountFix` and `K02MountFix` → `*.old` (ADM regenerates them on reinstall/upgrade).
1. Replace `fuser -m` with a per-path process check that scans `/proc` (no new dependencies, works on BusyBox):

   ```sh
   # Print PIDs of processes using anything under any of the given path prefixes
   # (cwd, root, open fds, mmapped files).
   pids_using_paths() {
       for p in /proc/[0-9]*; do
           pid=${p#/proc/}
           [ "$pid" = "$$" ] && continue
           hit=0
           for l in "$p/cwd" "$p/root" "$p"/fd/*; do
               t=$(readlink "$l" 2>/dev/null) || continue
               for prefix in "$@"; do
                   case "$t" in "$prefix"|"$prefix"/*) hit=1; break 2 ;; esac
               done
           done
           if [ $hit -eq 0 ]; then
               for prefix in "$@"; do
                   grep -q " $prefix/" "$p/maps" 2>/dev/null && { hit=1; break; }
               done
           fi
           [ $hit -eq 1 ] && echo "$pid"
       done
   }
   ```

   Check **both** prefixes: `$TGT` (`/volume1/.@plugins/AppCentral/<pkg>`) and `$SRC` (`/volumeX/AppCentral/<pkg>`). `/usr/local/AppCentral/<pkg>` is a symlink into `/volume1/.@plugins/...`, so `readlink` already resolves it.

2. New `stop` branch:

   ```sh
   stop)
       is_mounted "$SRC" "$TGT" || continue          # not mounted → nothing to do
       waited=0
       while [ -n "$(pids_using_paths "$TGT" "$SRC")" ] && [ $waited -lt 10 ]; do
           sleep 2; waited=$((waited + 2))          # short grace for apps still stopping
       done
       busy=$(pids_using_paths "$TGT" "$SRC")
       if [ -n "$busy" ]; then
           echo "Skipping unmount of $TGT: in use by PID(s) $busy" >&2
           continue                                  # never kill, never lazy-unmount
       fi
       sync
       umount "$TGT" || echo "umount $TGT failed (submounts?), leaving it mounted" >&2
       ;;
   ```

3. Unmount in **reverse** mount order. BusyBox may lack `tac`; use `sed -n '1!G;h;$p'`.
4. No `umount -R`. If nested mounts exist (docker-ce), a failed `umount` is the correct outcome — log and leave it; the kernel unmounts everything at power-off anyway.
5. `restart` currently calls `$0 stop; sleep 2; $0 start` — with the new logic it becomes a no-op for busy mounts, which is fine.
6. Optional: log to a file (e.g. `/var/log/mountfix.log` or `/tmp/mountfix.log`) with timestamps — today the output of init scripts is lost.

**Acceptance criteria**

- `fuser` and `umount -l` no longer appear in `CONTROL/start-stop.sh`; no `kill`/`-k` anywhere in the stop path.
- `CONTROL/start-stop.sh.old` exists in git with the original content and is not present in the built `.apk`.
- New test `tests/test_stop_safety.sh` (real behaviour, not grep), runnable in WSL with temp dirs and env overrides:
  - a `sleep 300` process with `cwd` inside a fake `$TGT/sub` is reported by `pids_using_paths`;
  - a process with `cwd` in a sibling app dir is **not** reported;
  - prefix collision (`.../perl` vs `.../perl5`) does not produce a false positive;
  - an entry that is not mounted is skipped without waiting.
- Manual check on the NAS (with the user present): with Docker running, `sudo /usr/local/etc/init.d/K02MountFix stop` must leave `docker-ce` mounted, kill nothing, and print the "Skipping unmount" message.

---

### F2 🔴 Boot-time mounting depends on `jq` from Entware, which is not available at S02

**Where:** `CONTROL/common.sh:20,30` (`get_mount_configs`), `CONTROL/start-stop.sh:20-24`

**Problem**

- `get_mount_configs` parses the config with `jq`. At boot `S02MountFix` runs **before** `S52entware`; `jq` is only at `/usr/local/AppCentral/entware/opt/bin/jq`, and `start-stop.sh` does not extend `PATH` at all (the `/opt/bin` added in `webman/scripts/common.sh` did not exist on the NAS either).
- If `jq` is missing, `get_mount_configs` fails → `start-stop.sh` exits 1 → **nothing is mounted** → every relocated app starts from its stale HDD copy without any visible error.
- Additionally, `entware` is itself relocated by MountFix, so the tool needed to perform the mount lives on the thing being mounted (it only works today because the stale HDD copy of Entware still exists underneath).

**Impact** Silent split-brain after every reboot (see also F3). Not confirmed by an actual reboot during the review — must be verified.

**Proposed fix** (pick one, in order of preference)

1. **Remove the `jq` dependency from the boot path.** Have `config.cgi set` (which runs from the UI, where Entware is available) additionally write a trivial pre-parsed file, e.g. `etc/mounts.list` with one `SRC:TGT` line per app. `start-stop.sh` reads only that file with plain `sh` (`while IFS=: read …`). Keep `mountfix.conf` (JSON) as the UI's source of truth.
2. Alternatively parse the (machine-written, single-line) JSON with `sed`/`awk` — acceptable because the writer is controlled, but more brittle.
3. At minimum: `PATH="$PATH:/usr/local/AppCentral/entware/opt/bin:/opt/bin"` and a loud log line when `jq` is missing. This does **not** solve the circular dependency.

**Acceptance criteria** `start-stop.sh start` works with `PATH=/bin:/usr/bin` and no `jq` installed (add a test that runs it with a stripped `PATH` against temp dirs). After a real reboot of the NAS, all configured apps are bind-mounted (`grep AppCentral /proc/mounts`).

---

### F3 🔴 Runtime mount state and boot configuration are independent

**Where:** UI `webman/mf_actions.js` — `bindMountAction()` (Mount/Unmount buttons, l.420) vs `saveConfig()` (Apply button, l.102) and the "Mount" check column in `webman/mf_core.js:158`.

**Problem** Clicking **Mount** mounts immediately but does not add the app to `selectedApps`; the boot config only changes when the checkbox is ticked **and** *Apply* is pressed. Conversely, an app can be selected in config but never copied/mounted.

**Impact** Mount without Apply → after reboot the app runs from the HDD copy and writes there; a later Mount hides those writes under the SSD copy. Two diverging copies, no warning.

**Proposed fix**

- Make `mount.cgi` the single writer of mount intent: on successful `mount` add the app to `selectedApps`, on successful `unmount` remove it (reuse `save_mountfix_config` with its backup rotation). Remove the separate "Mount" checkbox column (or make it read-only, reflecting config).
- In `validate.cgi`, report a mismatch flag per app (`configured != mounted`) and show it in the grid ("Will not be mounted after reboot" / "Configured but not mounted").

**Acceptance criteria** After Mount/Unmount from the UI, `etc/mountfix.conf` (and `mounts.list` from F2) reflect the change without pressing Apply; the grid shows a warning for any mismatch.

---

### F4 🔴 rsync flags are unsafe for Docker and for sync-back

**Where:** `webman/scripts/common.sh:449` (`start_app_transfer`), `:515` (`start_app_sync_back`)

**Problem**

- `rsync -au` lacks `-H` (hard links) and `-X`/`-A` (xattrs/ACLs). Docker's `overlay2` relies on xattrs (`trusted.overlay.*`, opaque dirs) and hard links; copying `docker-ce` without them can produce a broken image store.
- No `--delete`: files deleted on the SSD come back on the HDD after sync-back (and stale files remain on the SSD after a forced re-copy).
- `-u` decides by mtime only — for databases this can produce an inconsistent mix of old and new files.
- "App is stopped" is enforced **only in the UI** (`updateActionsUI`), and the UI uses the `enabled` flag from `installed.json`, which means *enabled in AppCentral*, not *running*.

**Proposed fix**

- Use `rsync -aHAX --numeric-ids` for both directions (verify that the Entware rsync build supports `-A`/`-X`; fall back to `-aHX` if ACLs are unsupported).
- Sync-back: offer `--delete` as the default for a true mirror, with a clear confirmation in the UI ("HDD copy will be made identical to SSD"). For the initial copy with `force=1`, use `--delete` as well so the target is an exact mirror.
- Drop `-u` for mirror operations (the app is stopped, the source is authoritative).
- Server-side guard: refuse migrate/sync-back/mount/unmount if `pids_using_paths` (from F1, moved to a shared library — see F6) finds processes using the app directory.

**Acceptance criteria** Test with a temp tree containing a hard link and an xattr (`setfattr -n user.test -v 1`): both are preserved after migrate and sync-back; a file deleted on the source disappears on the destination in mirror mode; CGIs return an error when a process holds the app dir.

---

### F5 🟠 No server-side validation of config; no session check in CGIs

**Where:** `webman/config.cgi:39-47`, `webman/scripts/common.sh:85` (`save_mountfix_config`), `CONTROL/common.sh:30`; all `webman/*.cgi`.

**Problem**

- `config.cgi?act=set` stores any syntactically valid JSON. `targetVolume` and `selectedApps[].name` are not validated, yet `start-stop.sh` (running as root at boot) builds `mount --bind` paths from them (e.g. `"name": "../../x"`).
- `validate.cgi` passes unvalidated `target`/`app` into `du`/`stat` paths.
- No CGI checks the `sid` the UI sends (`getApiUrlWithSid`). If ADM does not enforce authentication for app CGIs, any LAN client could change config or trigger mounts as root. **Unverified** — check how ADM serves `apps/MountFix/*.cgi` without a session.

**Proposed fix**

- In `save_mountfix_config`: validate with `jq` that `targetVolume` matches `^/volume[0-9]+$` and every `selectedApps[].name` matches the existing `validate_app_name` regex and exists in `/volume1/.@plugins/AppCentral/`; reject otherwise. Normalise to `{targetVolume, selectedApps:[{name}]}`.
- In `CONTROL/common.sh` (boot path), re-validate each line before mounting (defence in depth).
- In `validate.cgi`: run `validate_target_volume` / `validate_app_name` on inputs.
- Verify ADM's session enforcement; if absent, validate `sid` against ADM's session API (look at how other ADM apps' CGIs do it) or at least restrict mutating actions to POST.

---

### F6 🟠 Duplicated logic and inconsistent paths between the two shell libraries

**Where:** `CONTROL/common.sh` vs `webman/scripts/common.sh`; `CONTROL/start-stop.sh:26` (`is_mounted`) vs `webman/scripts/common.sh:294` (`is_app_bind_mounted`).

**Problem** Two implementations of path building and mount detection. Paths are hard-coded differently (`/volume1/.@plugins/AppCentral/...` vs `/usr/local/AppCentral/MountFix/...`); `VOLUME_ROOT`/`DIR_*` test overrides exist only in the webman library. Dead code: `is_ssd()` (superseded by `get_volume_rotational`), `DIR_MF_PLUGINS`. Config file path is hard-coded in three places.

**Proposed fix** One POSIX library (e.g. `CONTROL/lib.sh`, shipped once and sourced by both `start-stop.sh` and the CGIs) with: path helpers, validators, `is_app_bind_mounted`, `pids_using_paths`, config read/write, `json_escape`. Single `MF_ROOT`/`CONFIG_FILE` definition with env overrides for tests. Remove dead code.

---

### F7 🟠 CGI response handling is inconsistent

**Where:** `webman/*.cgi`, `webman/scripts/common.sh:59` (`send_response`)

- Three different `send_response` variants (`common.sh`, a redefinition in `migrate.cgi:20`, inline `echo` in `mount.cgi`/`validate.cgi`).
- `migrate.cgi` always wraps the result in `success: true`, even when the inner result is a failure (UI compensates with `res.success`).
- Unknown `act` in `migrate.cgi:38` and `config.cgi` (no `else`) → output without HTTP header or empty output → broken response.
- JSON is built with string concatenation/`printf` without escaping (`get_volumes_json`, `validate.cgi`, `start_app_transfer` `src`/`tgt`).
- File modes differ: `mount.cgi` is `755`, the other CGIs `644`.
- `config.cgi` fallback version `0.0.0.95` is hard-coded and stale.

**Proposed fix** One `send_json` helper (header + body, correct `success` propagation, escaping via `jq -n --arg` when available or a `json_escape` function). Every CGI handles unknown actions with a proper error response. Normalise file modes to `755`. Replace the hard-coded fallback version with `"unknown"`.

---

### F8 🟠 Transfer status: one global file, loose locking, premature "completed"

**Where:** `webman/scripts/common.sh:399` (`STATUS_FILE`), `:437`/`:503` (`pgrep -f "rsync.*$app_name"`), UI `monitorMigrationStatus` (`mf_actions.js:454`).

- Single `/tmp/mountfix_transfer.status` and single FIFO per direction: two concurrent operations overwrite each other's status.
- `pgrep -f "rsync.*$app_name"` matches substrings (`perl` matches `perl5`, any rsync whose args contain the name).
- UI treats `progress >= 100` as finished; `--info=progress2` can report 100 % before rsync has exited. The user may click Mount while rsync is still finalising.
- Fixed `/tmp` file names (`/tmp/mountfix_mount.err`, pipes) used as root.

**Proposed fix** One global lock (`mkdir /tmp/mountfix.lock` as an atomic mutex, with PID inside and stale-lock detection) — only one transfer at a time is the simplest correct model. Status file includes the rsync PID and a final `DONE`/`ERROR` marker written **after** `wait`; UI finishes only on that marker. Use `mktemp` for err files and the FIFO.

---

### F9 🟡 UI code quality

**Where:** `webman/mf_actions.js`, `webman/mf_core.js`

- `maskStack: []` is defined on the class prototype → shared between instances (re-opening the window can inherit a stale stack).
- `monitorMigrationStatus` uses `setInterval(…, 500)` with no in-flight guard and is never cleared when the window closes.
- Debug leftovers: `window.qq = this` (l.82), `console.log` calls, `console.log('copy to target')` in `mf_core.js:237`.
- Dead code: `getApps()` (result unused), `requestConfig()` (uses non-existent `me.apiUrl`), unused `status` grid column data, empty `webman/langs/lang-en-US.js`.
- The "Enabled" column is labelled *Running/Stopped* but shows AppCentral's `enabled` flag (see F4).
- `validate()` re-runs full `du` scans for all apps and masks the whole window (already analysed in `IDEAS.md` §1 — implement Approach A + B from there).

**Proposed fix** Initialise `maskStack` in the constructor; store interval id and clear it on `beforeclose`; use `setTimeout` chaining instead of `setInterval`; remove debug/dead code; rename the column or source a real "running" state; implement `IDEAS.md` §1 A+B.

---

### F10 🟡 Build, repository hygiene and tests

- `webman/mountfix.js` is a **generated** file (concatenation of `mf_actions.js`, `mf_core.js`, `mf_main.js`) but is committed; it is currently in sync, but will drift. Either stop tracking it (build generates it into the temp package dir anyway) or add a test that fails when it differs from a fresh concatenation.
- `build.sh` bumps the version in `CONTROL/config.json` **and** rewrites `webman/mf_core.js` on every build → every local build dirties tracked files. Consider deriving the displayed version only from `config.json` at runtime (already returned by `config.cgi`) and dropping the hard-coded `value: '0.0.0.102'` in `mf_core.js:270`.
- Two packagers (`toolchain/apkg-tools_py3.py` and `toolchain/apkg-tools.sh`); `build.sh` uses the shell one. Remove or document the Python one.
- `out/` is owned by root (from older `sudo` builds) → `build.sh` re-execs with `sudo`. A one-time `sudo chown -R $USER out` removes the need.
- `tests/test_end_to_end_build.sh` **fails** in WSL: `zip: command not found` (missing dev dependency — document it or check for it). Other 4 tests pass.
- Most tests are `grep` checks on source text rather than behaviour; `tests/test_ui_build.sh` runs `./buildJs.sh` which rewrites the tracked `webman/mountfix.js`. Add a `tests/run_all.sh` and prefer behavioural tests (see acceptance criteria above).
- `etc/mountfix.conf` (shipped default) pre-selects `docker-ce` → a fresh install would try to bind-mount Docker at the next boot if `/volume2/AppCentral/docker-ce` exists. Default should be `{"targetVolume":"","selectedApps":[]}`.
- `CONTROL/pre-uninstall.sh` contains unrelated MySQL comments and does nothing — on uninstall it should refuse (or warn) while apps are still bind-mounted.
- `README.md` mentions `S01mountfix`; the actual init script is `S02MountFix`/`K02MountFix` (`boot-priority` 2).
- `.aiexclude` / `GEMINI.md` entries are leftovers from another tool — keep or remove deliberately.
- `feature/mountfix-safety-sync` is not merged into `master`; after these fixes, merge so `master` again matches what is deployed.

---

### F11 🟡 Global `sysctl` tuning is applied silently on every start/stop

**Where:** `CONTROL/start-stop.sh:11-17`

The script changes system-wide kernel settings on **every** invocation (including `stop`): `swappiness=1`, `vfs_cache_pressure=10`, `dirty_writeback_centisecs=6000`, `dirty_expire_centisecs=6000`. The last two widen the window of data loss on power failure to ~60 s for **all** volumes, not just relocated apps, and are not visible in the UI.

**Proposed fix** Apply only on `start`; make it an explicit option in config/UI (default off or clearly documented); log the old values so they can be restored on `stop`/uninstall.

---

## 4. Implementation status & remaining roadmap

| # | Finding | Status | Notes |
|---|---|---|---|
| 1 | **F1** Safe `stop` path (`start-stop.sh.old` backup, no `fuser`/`umount -l`, `umount`-first fast path, `/proc/mounts` fallback, shutdown-gated per-path `SIGTERM`→`SIGKILL`) | ✅ **Done & verified (`0.0.0.103`–`0.0.0.105`)** | Verified on ADM 5.1.5: normal upgrades skip busy apps safely; real reboot unmounts all 5 apps in ~15 s with zero `stormand` hang. |
| 2 | **F2** Boot & shutdown without `jq` (`etc/mounts.list` + `post-install.sh` upgrade generation) | ✅ **Done & verified (`0.0.0.103`)** | Verified with stripped `PATH` in `tests/test_stop_safety.sh` and across two real NAS reboots (`< 1 s` mount time). |
| 3 | **F11** `sysctl` tuning on `start` only | 🟡 **Partial (`0.0.0.103`)** | Moved out of `stop` so shutdown never alters dirty writeback timers; UI toggle / restore on uninstall still optional. |
| 4 | **F6** Shared POSIX shell library (`CONTROL/lib.sh`) | ✅ **Done (`0.0.0.106`)** | `CONTROL/lib.sh` is sourced by `start-stop.sh`, `post-install.sh` and `webman/scripts/common.sh`. `CONTROL/common.sh` is a temporary shim — **remove in Branch 4**. |
| 5 | **F3** Runtime mount state = boot config (`mount.cgi` updates config + `mounts.list`, mismatch warning in grid) | ⏳ Pending (Stage 2) | Prevents UI mount without *Apply* from diverging on reboot. |
| 6 | **F4**, **F12** Safe `rsync` flags (`-aHAX`), server-side running check, non-blocking `migrate.cgi` background FD redirection | ✅ **Done (`0.0.0.107`)** | Detached background subshell (`</dev/null >/dev/null 2>&1 &`), unbuffered progress streaming, `detect_rsync_flags` (`-aH --numeric-ids` + probed `-A`/`-X`/`--outbuf=L`), mirror `--delete` with UI confirmations, and `ensure_app_not_busy` across migrate/sync-back/mount/unmount. |
| 7 | **F13**, **F14**, **F15** NVMe SSD detection & `df -Ph`, self-relocation guard (`MountFix`), `pre-install.sh` `PATH` | 🟡 **Partial** — `F13`, `F14` ✅ done (`0.0.0.106`); `F15` ⏳ pending (Branch 4) | Unblocks NVMe volumes and prevents relocating `MountFix` itself. |
| 8 | **F5**, **F7**, **F8** Config input validation, unified CGI JSON responses, atomic transfer lock + `DONE` marker | ✅ **Done (`0.0.0.106`–`0.0.0.107`)** | `F5`, `F7` in `0.0.0.106`; `F8` in `0.0.0.107` (atomic `/tmp/mountfix.lock` mutex with stale-lock recovery, `mktemp` error files/FIFOs, explicit `DONE`/`ERROR` state markers). `POST`-only enforcement for mutating CGIs is deferred to Branch 3 (needs `mf_actions.js` changes). |
| 9 | **F9**, **F10**, **F16**, **F17** UI cleanup, double-`validate()` fix, single-app `du` optimization (`IDEAS.md` §1), `pre-uninstall.sh` mount guard | ⏳ Pending (Stage 2) | UX responsiveness and repository hygiene. |

### 4.1 Stage 2 Execution Plan (Agreed Branch & Commit Grouping)

To avoid merge conflicts in `webman/scripts/common.sh` and `webman/mf_actions.js` and avoid 15 separate `.apk` deployments on the NAS, Stage 2 work is grouped into **4 sequential feature branches** (1 branch = 1 `.apk` release verification), each structured into **2–3 small, revertible atomic commits**:

1. **Branch 1: `refactor/shared-lib-and-cgi-hardening`** ✅ **Done (`0.0.0.106`, merged to `master`, see §8)** *(backend foundation — implement first so subsequent branches target a single library)*
   - **Commit 1 (`F6` + `F14` + shell items from `F17`):** Extract shared POSIX `CONTROL/lib.sh` (path builders, validators, `is_app_bind_mounted`, `pids_using_paths`), block self-relocation of `MountFix` (with warning note for `entware`), fix `url_decode` (`printf '%b'` + case-insensitive hex), and remove `readonly` re-sourcing traps.
   - **Commit 2 (`F5` + `F7`):** Introduce unified `send_json` response helper with proper escaping, validate inputs across `save_mountfix_config` and all `webman/*.cgi`, handle unknown `act` actions, normalize `*.cgi` permissions to `755`, remove hard-coded fallback version in `config.cgi`, and verify/enforce ADM `sid` session authentication.
   - **Commit 3 (`F13`):** Fix NVMe partition-to-disk resolution (`nvme0n1p1` → `nvme0n1`) in `get_volume_rotational` and use `df -Ph` in `get_volumes_json`.

2. **Branch 2: `fix/transfer-engine`** ✅ **Done (`0.0.0.107`, see §9)** *(data migration & sync-back engine — touches the same ~80 lines of `start_app_transfer` / `start_app_sync_back`)*
   - **Commit 1 (`F12` + `F8`):** Redirect background subshell FDs (`</dev/null >/dev/null 2>&1`) so `migrate.cgi` returns immediately, avoid block-buffered `tr` progress stalls, add atomic `/tmp/mountfix.lock` mutex, replace fixed `/tmp` filenames with `mktemp`, and emit explicit `DONE`/`ERROR` status markers after `wait`.
   - **Commit 2 (`F4`):** Switch transfers to `rsync -aHAX --numeric-ids` (after verifying `-A`/`-X` support on the target NAS), unify destination path handling before enabling optional `--delete` mirror mode, and enforce a server-side `pids_using_paths` check rejecting transfers/mounts/unmounts while processes hold the app directory.

3. **Branch 3: `fix/ui-state-and-validation`** *(UI ↔ boot config consistency, responsiveness & JS cleanup)*
   - **Commit 1 (`F3`):** Update `mount.cgi` so *Mount*/*Unmount* atomically updates `etc/mountfix.conf` and `etc/mounts.list` without requiring a separate *Apply* step, and expose `configured != mounted` mismatch warnings in `validate.cgi` and the ExtJS grid.
   - **Commit 2 (`F16` + `IDEAS.md` §1):** Suppress duplicate `validate()` firing on initial window open, stop running `validate()` concurrently with *Unmount & Sync-back*, pass single-app `validate(appName)` after per-app actions, and consolidate `du -sh` + `du -sk` into a single `du -sk` pass without full-window modal blocking.
   - **Commit 3 (`F9` + JS items from `F17`):** Move `maskStack` from prototype to instance, replace uncleaned `setInterval` polling with `beforeclose`-safe `setTimeout` chaining, remove dead `getApps()`/`apps.cgi` calls and debug leftovers (`window.qq`, `console.log`), drop unused POST body in `migrateSelectedApp`, and fix the `taskIcon` path typo.

4. **Branch 4: `chore/lifecycle-and-repo-hygiene`** *(installer hooks, build tooling & repository cleanup)*
   - **Commit 1 (`F15` + `F10` lifecycle):** Add Entware `PATH` and independent `jq`/`bash`/`rsync` checks in `CONTROL/pre-install.sh`, block package uninstall when bind mounts are active in `CONTROL/pre-uninstall.sh`, and clear pre-selected `docker-ce` from the shipped default `etc/mountfix.conf`.
   - **Commit 2 (`F10` build + `F11` remainder + repo cleanup):** Stop `build.sh` from dirtying tracked JS/version files on every local build, make `sysctl` writeback tuning an explicit config/UI option, remove the temporary `CONTROL/common.sh` compatibility shim, and clean up untracked `tools/` plus merged legacy branches.

---

## 5. What is already good (keep it)

- Mount detection via `stat -c %d:%i` inode/device comparison — more robust than parsing `mount` output.
- Input validation in the webman mount/transfer functions (`validate_app_name`, `validate_target_volume`).
- Atomic config write (`tmp` + `mv`) with backup rotation.
- UI guards (button enable/disable by state, confirmation before overwriting target data, unmount → sync-back flow).
- Correct stop ordering reasoning (`tests/test_start_stop.sh` documents ADM's `sort -r` for `K*` scripts).
- Good documentation baseline (`docs/ARCHITECTURE.md`, `IDEAS.md`).

---

## 6. Second-Pass Verification & Addendum

| | |
|---|---|
| **Date** | 2026-11-23 |
| **Reviewed revision** | branch `feature/mountfix-safety-sync`, commit `0854b46` |
| **Reviewer** | **Antigravity** — model **Gemini 4 Neon (High)** (agentic audit / verification mode) |
| **Scope** | Fact-check of sections 1–5 against the actual repository + audit for missed bugs and caveats in proposed fixes |

### 6.1 Fact-check of the original review (F1–F11)

All findings `F1`–`F11` are **verified and accurate** — there are no hallucinated issues, and the severity / implementation order is sound.

Minor corrections to references in sections 0–5:

- Line-number offsets in `webman/mf_core.js` (~44 lines off):
  - F3: "Mount" checkcolumn is at `mf_core.js:114-119` (not `:158`).
  - F9: `console.log('copy to target')` is at `mf_core.js:192` (not `:237`).
  - F10: `value: '0.0.0.102'` is at `mf_core.js:225` (not `:270`).
- Section 0 item 5 ("no bashisms"): existing scripts in `CONTROL/` and `webman/` already use `local` (supported by BusyBox `ash` and `dash`, though technically outside strict POSIX `sh`).

---

### 6.2 Additional findings missed in the original review

#### F12 🔴 `migrate.cgi` blocks until `rsync` finishes (background subshell leaks CGI stdout/stderr)

**Where:** `webman/scripts/common.sh:445-462` (`start_app_transfer`), `:511-528` (`start_app_sync_back`), `webman/migrate.cgi:29,32`

**Problem**

- `migrate.cgi` invokes `RESPONSE=$(start_app_transfer ...)` and `RESPONSE=$(start_app_sync_back ...)`.
- Inside both functions, the background subshell `( ... ) &` inherits the open stdout/stderr descriptors of the command substitution `$(...)` and of the CGI process (`lighttpd`) without redirecting them (`</dev/null >/dev/null 2>&1`).
- As a result, `$(...)` **blocks until the entire `rsync` job finishes** (verified with `sh`). The HTTP request hangs for the full transfer duration (risking browser/lighttpd timeouts on large apps like `docker-ce`), and the frontend 500 ms polling loop (`monitorMigrationStatus`) only starts *after* the transfer has already completed.
- Additionally, `cat "$pipe" | tr '\r' '\n' >> "$STATUS_FILE"` block-buffers stdout (typically 4–8 KB when not attached to a tty), so progress updates stall at `0%` on small/medium transfers until the buffer flushes or `rsync` exits.

**Proposed fix**

- Redirect all standard FDs on the background subshell: `( ... ) </dev/null >/dev/null 2>&1 &` (and ideally detach with `nohup` or `setsid` if available).
- Avoid block-buffered `tr` for progress updates (e.g. `stdbuf -oL tr` if available, or an `awk` / shell `IFS` loop / `rsync --outbuf=L` where supported).

**Acceptance criteria** Calling `RESPONSE=$(start_app_transfer ...)` with a slow mock `rsync` (e.g. `sleep 3`) returns in `< 0.5 s` while the background transfer continues and updates the status file incrementally.

---

#### F13 🔴 NVMe volumes are misclassified as HDDs and blocked in the UI; `df -h` can wrap lines

**Where:** `webman/scripts/common.sh:190` (`get_volume_rotational`), `:211` (`get_volumes_json`)

**Problem**

- `base_disk=$(echo "$first_slave" | sed 's/[0-9]*$//')` works for SATA partitions (`sdd4` → `sdd`), but turns NVMe partitions (`nvme0n1p1`, `nvme1n1p4`) into `nvme0n1p` instead of `nvme0n1`.
- Neither `/sys/block/nvme0n1p/queue/rotational` nor `/sys/block/nvme0n1p1/queue/rotational` exists, so `get_volume_rotational` falls back to `1` (HDD). Because `mf_core.js:70` blocks selecting non-SSD volumes (`beforeselect: return record.get('isSSD')`), **NVMe volumes cannot be selected at all**.
- In `get_volumes_json`, `df -h "$VOL" | awk 'NR==2'` omits `-P` (POSIX single-line output). For long device names (e.g. `/dev/mapper/...`), `df` wraps onto two lines, shifting `TOTAL`, `FREE`, and `USE_PCT` to wrong/empty values.

**Proposed fix**

- Resolve the base block device cleanly for both SATA and NVMe (e.g. strip `p[0-9]+$` for `nvme*`/`mmcblk*` and `[0-9]+$` for `sd*`/`hd*`/`vd*`, or read `/sys/class/block/$first_slave/../queue/rotational` via `readlink -f`).
- Use `df -Ph "$VOL" | awk 'NR==2'` (verify `-P` works on ADM's BusyBox `df`; otherwise `df -h "$VOL" | awk 'NR>1 { ... }'`).

**Acceptance criteria** Unit test covering `sdd4` → `sdd`, `nvme0n1p1` → `nvme0n1`, `nvme0n1` → `nvme0n1`, and long wrapped `df` output.

---

#### F14 🟠 No guard preventing relocation or unmount of `MountFix` itself

**Where:** `webman/scripts/common.sh` (`get_installed_apps_json`, `mount_app`, `unmount_app`, `start_app_transfer`, `start_app_sync_back`), `webman/validate.cgi`

**Problem** Neither the UI nor the backend excludes `MountFix` from the selectable/actionable app list. A user can attempt to copy, bind-mount, or unmount `MountFix` while its own CGI scripts are executing from `/volume1/.@plugins/AppCentral/MountFix`.

**Proposed fix** Reject `MountFix` server-side in `validate_app_name` (or a dedicated `is_protected_app` guard in mount/unmount/transfer/config save) and hide/disable it in the UI. Also consider warning clearly when relocating `entware` (boot-time dependency, see F2).

---

#### F15 🟠 `CONTROL/pre-install.sh` invokes `opkg` without Entware on `PATH` and skips `rsync` check

**Where:** `CONTROL/pre-install.sh:5-10`

**Problem**

- As verified in section 2, Entware binaries live in `/usr/local/AppCentral/entware/opt/bin` and are not on the default `PATH`. Calling `opkg update` / `opkg install` without extending `PATH` fails on systems where `/opt/bin` is missing.
- `opkg install bash` is inside `if ! command -v jq`, so `bash` is skipped if `jq` is already installed.
- `rsync` availability (and support for `--info=progress2`) is never checked during install.

**Proposed fix** Export `PATH="$PATH:/usr/local/AppCentral/entware/opt/bin:/opt/bin:/opt/sbin"` in `pre-install.sh`, check required packages individually, and verify whether `rsync` is provided by ADM or needs installing via `opkg`.

---

#### F16 🟠 Double `validate()` on window open and race condition during "Unmount & Sync-back"

**Where:** `webman/mf_actions.js:90-92`, `:436-442`; `webman/mf_core.js:72-74`

**Problem**

- On window open, `loadConfig()` calls `setMfConfig()` → `combo.setValue(...)`, which fires the combo `change` listener (`fn.validate()` #1), and two lines later `loadConfig()` explicitly calls `page.validate()` #2 — launching two concurrent full `du` scans across `/volume1`.
- During "Unmount & Sync-back", `bindMountAction()` fires `page.validate()` and `onSuccessCallback()` (`syncBackSelectedApp()`) **in parallel**. `du` scans the HDD while `rsync` is actively writing to it, and when `validate()` finishes it mutates `maskStack` and overwrites the live transfer progress mask.

**Proposed fix** Suppress/suspend the combo `change` event during `setMfConfig()` (`combo.suspendEvents(); combo.setValue(...); combo.resumeEvents();`). In `bindMountAction()`, do not run `validate()` in parallel with `onSuccessCallback` (either chain `syncBackSelectedApp` after unmount and let sync-back's completion run `validate(app)`, or await validation first).

---

#### F17 🟡 Minor missed defects (CGI, JS, shell hygiene)

- `url_decode()` (`webman/scripts/common.sh:52-54`) only matches uppercase hex (`[0-9A-F]`, ignoring `%2f`) and uses non-POSIX `echo -e` (prints literal `-e` under `dash`). Use `printf '%b'` and `[0-9A-Fa-f]`.
- `migrateSelectedApp()` (`webman/mf_actions.js:221`) sends `params: Ext.encode(page.getMfConfig())` as an unused POST body (copy-paste leftover from `saveConfig`); `migrate.cgi` only reads `QUERY_STRING`. Use `method: 'GET'` (or switch all mutating endpoints to POST per F5).
- `webman/mf_core.js:278` still calls dead `fn.getApps()` on every window open, firing an unused HTTP request to `webman/apps.cgi` (which is also the only CGI using `#!/usr/bin/env sh` instead of `#!/bin/sh`).
- Typo in `webman/mf_core.js:269`: `taskIcon: '..apps/MountFix/images/icon-app-task.png'` (missing `/` after `..`).
- `readonly DIR_VOL1` etc. (`webman/scripts/common.sh:5-12`) cause errors if the library is sourced more than once in the same shell session (e.g. test harnesses).

---

### 6.3 Caveats & refinements for existing proposals (`F1`, `F2`, `F4`)

- **F2 (`etc/mounts.list`) — Upgrade migration gap:** If an existing NAS upgrades from `0.0.0.102` (which only has `etc/mountfix.conf`) and reboots *before* anyone saves from the UI, `etc/mounts.list` will not exist yet and `start-stop.sh` will mount nothing. **`CONTROL/post-install.sh` (in the `upgrade` branch, when Entware is running) must generate `etc/mounts.list` from the restored `etc/mountfix.conf`**, and/or `start-stop.sh` should keep a fallback if `mounts.list` is absent.
- **F1 (`pids_using_paths`) — Three operational details:**
  1. Also include `"$p/exe"` in the `readlink` loop (in addition to `cwd`, `root`, `fd/*`).
  2. Processes accessing a relocated app through an alternate bind mount (e.g. `/opt/...` for `entware`) may not show `$TGT` in `/proc/$pid/fd/*` — keeping non-lazy `umount` safely catches this via `EBUSY`.
  3. Iterating `readlink` per FD for all processes on a NAS running Docker can take several seconds per pass under BusyBox `ash`, making `waited=$((waited + 2))` drift well past 10 s of wall-clock time; track wall-clock time (`date +%s`) or cap iterations conservatively.
- **F4 (`rsync -aHAX --delete`) — Destination path & NAS capability check:**
  1. Today `start_app_transfer` calls `rsync ... "$src" "$tgt"` where `$tgt` is `/volumeX/AppCentral` (parent dir), whereas `start_app_sync_back` uses `"$src/" "$tgt/"` (app dir). Before adding `--delete`, unify `start_app_transfer` to `mkdir -p "$tgt_app" && rsync ... --delete "$src/" "$tgt_app/"` so a trailing slash mistake can never wipe sibling apps in `/volumeX/AppCentral/`.
  2. Test `rsync -aHAX --numeric-ids` directly on the target NAS first — if the underlying filesystem or Entware `rsync` build rejects ACLs (`-A`) or `trusted.*` xattrs (`-X`), `rsync` exits with code `23` and fails the transfer.

---

*Addendum authored by **Antigravity** (model: **Gemini 4 Neon (High)**, mode: **read-only technical verification & audit**) on 2026-11-23.*

---

## 7. Field Verification & Shutdown Refinement (2026-11-24)

### 7.1 Production Incident & Reboot Verification (`0.0.0.102` → `0.0.0.103`)

During the ADM firmware upgrade (`5.1.4.RM62` → `5.1.5.RNN1`) on `0.0.0.102`, both **F2** and **F1** manifested in production:

1. **Before `0.0.0.103` (F2 confirmed):** `K52entware` stopped before `K02MountFix` and removed `/opt/bin`. `K02MountFix stop` failed on missing `jq` and exited 1 without unmounting anything. `S21stormand stop` then hung for 60 s on busy cross-volume bind mounts (`/volume2` mounted inside `/volume1`) until ADM's `/etc/script/script_trap.sh` sent `SIGKILL` (`Forced stop 'stormand' service`). On boot, `S02MountFix start` applied `sysctl` and then exited 1 on missing `jq`, causing all 4 apps (`docker-ce`, `minidlna`, `download-center`, `entware`) to start from stale HDD copies on `/volume1`.
2. **After `0.0.0.103` (boot fixed; remaining shutdown edge case found):**
   - **Boot (`S02MountFix start`)** succeeded in `< 1 s` without `jq`; all configured apps mounted from `/volume2` and Docker started all containers cleanly.
   - **Controlled reboot (`K02MountFix stop`)** cleanly unmounted `docker-ce`, `download-center`, and `minidlna`, and logged the exact 6 PIDs still holding `entware` (`17299 17454 17471 17473 17474 17501`).
   - **Why `entware` stayed busy:** ADM stops AppCentral plugins (`rcK.pluginsfs`) **before** built-in services (`rcK.builtinfs`, including `sshd`). Active user SSH sessions running Entware `bash`/`tmux` keep `/volume2/AppCentral/entware/opt/...` open when `K02MountFix` runs. Because `0.0.0.103` skipped unmounting `entware`, `stormand` still hit `EBUSY` 90 s later.
   - **Performance observation:** Scanning `/proc` via BusyBox `readlink` + `awk` took ~5 s per pass (2 passes per idle mount = ~31 s total for 4 mounts).

### 7.2 Targeted Fixes (`0.0.0.104`–`0.0.0.105`, branch `fix/shutdown-fast-unmount`)

1. **`umount`-first fast path in `CONTROL/start-stop.sh`:**
   - Plain non-lazy `umount "$tgt"` is atomic in the Linux kernel: idle mounts unmount in `~0.01 s`, while busy mounts immediately return `EBUSY` with no side effects.
   - Only run `pids_using_paths` when `umount` actually returns `EBUSY` (and avoid running it twice per iteration). Cuts typical `stop` time from ~31 s to ~1 s.
2. **Shutdown-aware per-path cleanup (gated strictly on `/var/log/halt-action`):**
   - ADM writes `REBOOT` or `SHUTDOWN` to `/var/log/halt-action` before running `rcK.raminitfs` → `rcK.builtinfs` → `rcK.pluginsfs`; during normal runtime (manual stop/disable/upgrade in AppCentral) the file is empty.
   - **Normal runtime (`halt-action` empty):** Never send signals; skip busy mounts and log `pid(comm)` (e.g. `10180(tmux: server) 10189(bash)`).
   - **Real `REBOOT`/`SHUTDOWN`:** If a mount is still `EBUSY` after the grace period, send `SIGTERM` (2 s) → `SIGKILL` (1 s) **only to the exact PIDs returned by `pids_using_paths`** (never `fuser -k -m`), then perform a clean non-lazy `umount` so `stormand` can cleanly unmount `/volume2` and `/volume1`.
3. **ADM Syslog severity (`0.0.0.105`):**
   - Adjusted `/usr/sbin/syslog` calls in `log_warn()` from `--level 2` (ADM Error, stored as `lvl=4` in `Log_System`) to `--level 1` (ADM Warning, `lvl=2`), matching ADM's own `/etc/script/script_trap.sh` convention.

### 7.3 Design Note: Disabling MountFix While Apps Are Running

- **Current safe behaviour:** Disabling or upgrading MountFix in AppCentral while relocated apps are running will **not** crash those apps — `stop` skips busy mounts and leaves them running on `/volume2`. (Disabling MountFix only prevents `S02MountFix` from running on the *next* boot.)
- **Returning apps to HDD (`/volume1`):** The safe sequence is *Stop app → Unmount → Sync-back (SSD → HDD) → Start app*.
- **Why auto-stop / auto-sync-back / auto-restart must NOT live in `start-stop.sh stop`:**
  1. ADM invokes `stop` during every MountFix package upgrade — stopping Docker or running multi-GB `rsync` during an upgrade is undesirable.
  2. ADM's `script_trap.sh` enforces a hard **60 s** timeout on `stop`, which would `SIGKILL` `rsync` mid-transfer.
- **Future UI consideration (Stage 2):** If a one-click rollback is desired, implement it as an explicit UI workflow (e.g., *"Revert to HDD"* / per-app *Unmount & Sync-back* with optional restart prompt) running asynchronously outside init timeouts, paired with an active-mount guard in `CONTROL/pre-uninstall.sh` (F10).

### 7.4 Production Verification of `0.0.0.105` (Clean Reboot Confirmed)

Verified on ASUSTOR AS5304T (ADM `5.1.5.RNN1`) with 5 relocated apps (`entware`, `minidlna`, `photogallery`, `download-center`, `docker-ce`):

- **Live package upgrade (`0.0.0.104` → `0.0.0.105`):** With `halt-action` empty, `stop` logged `pid(comm)` warnings (`lvl=2` in `Log_System`), killed zero processes, and left Docker containers and apps running uninterrupted.
- **Controlled NAS reboot (`15:20:10–15:20:25`):**
  - `docker-ce`, `download-center`, `photogallery`, and `minidlna` unmounted in **1 second** (`15:20:11`) via the `umount`-first fast path.
  - `entware` detected `10177(tmux: client) 10180(tmux: server) 10189(bash)`, logged an ADM Warning (`lvl=2`), sent `SIGTERM`, and unmounted cleanly 2 seconds later (`15:20:25`).
  - **Result in ADM `Log_System`:** Zero `Forced stop 'stormand' service` errors and zero `The NAS did not shut down properly last time.` warnings.
- **Boot (`15:24:19`):** All 5 apps bind-mounted from `/volume2` in **< 1 second** (`stat -c %d:%i` matched across all 5), and all Docker containers (`PortainerCE`, `Forgejo`, `openclaw-gateway`), Photo Gallery, MiniDLNA, and Download Center started cleanly on `/volume2`.


---

## 8. Stage 2 — Branch 1 Results (`refactor/shared-lib-and-cgi-hardening`, `0.0.0.106`)

Implemented as 3 atomic commits plus one fix wave, each task reviewed (spec + quality) and a whole-branch review at the end. Installed and checked read-only on the NAS (ADM 5.1.5): all 5 relocated apps stayed mounted through the upgrade (`Already mounted` ×5 in `var/mountfix.log`), `mounts.list` regenerated.

| Commit | Findings | Summary |
|---|---|---|
| `bcb8229` | `F6`, `F14`, `F17` (shell) | `CONTROL/lib.sh` (path builders, validators, `is_mounted`, `pids_using_paths`, `json_escape`, `mounts.list` helpers), `MountFix` blocked from relocation, POSIX `url_decode`, no `readonly`, dead code removed. |
| `18693f4` | `F5`, `F7` | `send_json` / `send_json_error`, fail-closed `require_adm_session`, strict `save_mountfix_config` validation + normalization, unknown `act` handled, CGIs `0755`, `"unknown"` fallback version. |
| `c2470bd` | `F13` | `resolve_base_block_device` (`nvme0n1p1` → `nvme0n1`), exact `/proc/mounts` lookup, `df -Ph` with wrapped-line handling. |
| `157d0d3` | fix wave | `act=get-nonstop` for `admin.cgi`, UI `failure(json)` handling, empty-output guard in `mount.cgi`. |

### 8.1 Field facts learned (ADM 5.1.5)

- **`lighttpd` does not authenticate `apps/<pkg>/*.cgi`** (verified: `config.cgi?act=get` without `sid` returned full JSON as `root`). Authentication is therefore done by the CGIs themselves.
- **Session check:** `/usr/webman/portal/apis/admin.cgi` can be run locally. After a valid admin `sid` it requires an `act`; `act=get-nonstop` is read-only and returns `{"success": true, ...}` for admins, `error_code 5000` for invalid sessions and `5301` when `act` is missing. `require_adm_session()` calls it with `act=get-nonstop&sid=<sid>` and fails closed.
- **`AS.ARC.ajax`** routes any response with top-level `"success": false` to `failure(json)`, not `success(json)`. The UI therefore reads `json.result.target_exists` / `json.result.error` in `failure` handlers.
- `df -Ph` works on the NAS BusyBox.
- BusyBox/POSIX `awk`: `gsub(/\\/, "\\\\")` does not escape backslashes — `json_escape` uses a `substr` loop instead (tests run with and without `POSIXLY_CORRECT=1`).

### 8.2 Open items carried forward

- **Branch 4:** remove the `CONTROL/common.sh` compatibility shim (marked `# shortcut:`).
- **Branch 3:** `entware` relocation warning in the UI; `POST`-only mutating CGIs together with `mf_actions.js`.
- **Deferred minors:** `url_decode` turns `%00` into an empty string (all decoded values are validated afterwards); `get_volume_rotational` relies on `PROC_MOUNTS` set by `lib.sh`.
- **Not verified live:** an authenticated UI session (volumes, app list, *Apply*, *Copy to target* with an existing target directory) after `0.0.0.106`. Multi-layer LVM (`dm-*`) volumes without direct `slaves/` fall back to HDD.


---

## 9. Stage 2 — Branch 2 Results (`fix/transfer-engine`, `0.0.0.107`)

Implemented as 2 atomic commits plus a version bump, verified locally with expanded behavioural tests (`tests/test_sync_back.sh`, `tests/test_ui_build.sh`).

| Commit | Findings | Summary |
|---|---|---|
| `3623346` | `F12`, `F8` | Detached background subshell (`</dev/null >/dev/null 2>&1 &` + `trap '' HUP`) so `migrate.cgi` returns immediately; unbuffered `_stream_rsync_progress` (`stdbuf -oL tr` + `awk` fallback); atomic `/tmp/mountfix.lock` mutex with `pid`/`owner` and stale-lock recovery; `mktemp` for mount/umount error files and per-transfer FIFO dir; atomic status writes (`_write_status_atomic`) with explicit `DONE` / `ERROR` markers and `state` / `pid` fields in `get_transfer_status_json()`; UI finishes only on `state === 'done'` (never prematurely at `100%`). |
| `c03e171` | `F4` | `detect_rsync_flags()` uses `-aH --numeric-ids` and probes both `rsync --version` and a live `--dry-run` on source/destination before enabling `-A`, `-X`, and `--outbuf=L`; dropped unsafe `-u`; unified trailing-slash app paths (`"$src/" "$dst/"`) before enabling `--delete` mirror mode on sync-back and `force=1` copy; added `ensure_app_not_busy()` (`pids_using_paths`) guard across `start_app_transfer`, `start_app_sync_back`, `mount_app`, and `unmount_app`; updated UI confirmation dialogs (`mf_actions.js` / `mountfix.js`) to warn explicitly about mirror mode (`--delete`) on forced copy, standalone sync-back, and unmount & sync-back. |
| `437ee7c` | release | Bumped package version to `0.0.0.107` (`CONTROL/config.json`, `webman/mf_core.js`, `webman/mountfix.js`). |

### 9.1 Key design points

- **Non-blocking CGI:** `RESPONSE=$(start_app_transfer ...)` returns in `< 0.5 s` while `rsync` continues in the background; `trap` on `EXIT` cleans up both the `mktemp -d` FIFO directory and `/tmp/mountfix.lock` (guarded by `owner` token so an exiting job never releases another job's lock).
- **Safe mirror semantics:** `start_app_transfer` always targets `$tgt_app/` (creating it if missing) rather than the parent `/volumeX/AppCentral`, preventing `--delete` from ever affecting sibling apps.
- **Filesystem-aware `-A`/`-X`:** `detect_rsync_flags` falls back cleanly to `-aH --numeric-ids` (or `-aHX` / `-aHA`) if the NAS `rsync` build or underlying filesystem rejects ACLs or xattrs during the `--dry-run` probe.

### 9.2 Open items carried forward

- **Pending live NAS verification (`0.0.0.107`):** Build `.apk` and verify on ADM 5.1.5 that Entware `rsync` capability probing (`-A`/`-X`/`--outbuf=L`), non-blocking progress polling, and mirror-mode confirmations behave as expected on real volumes.
- **Branch 3 (`fix/ui-state-and-validation`):** `F3`, `F9`, `F16`, JS items of `F17`, `IDEAS.md` §1, `entware` relocation warning, and `POST`-only mutating CGIs.
- **Branch 4 (`chore/lifecycle-and-repo-hygiene`):** `F15`, `F10`, `F11` (UI option), and removal of the `CONTROL/common.sh` shim.
