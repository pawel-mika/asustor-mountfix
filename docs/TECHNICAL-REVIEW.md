# MountFix — Technical Review, Findings & Proposed Fixes

| | |
|---|---|
| **Date** | 2026-11-19 |
| **Reviewed revision** | branch `feature/mountfix-safety-sync`, commit `96ac956` (package version `0.0.0.102`) |
| **Scope** | Whole repository: `CONTROL/`, `webman/` (CGI + shell library + ExtJS UI), `build.sh` / `buildJs.sh`, `tests/`, `etc/` |
| **Status** | Analysis only — **no code has been changed yet**. This document is the work order for the follow-up implementation. |

---

## 0. How to use this document (for the implementing agent)

1. Work on a **new branch** created from `feature/mountfix-safety-sync` (e.g. `fix/review-2026-11`). Do not commit to `master` directly; `master` is behind and does not match what is installed on the NAS.
2. Fix items **in priority order** (section 3). Each finding has: *Where*, *Problem*, *Impact*, *Proposed fix*, *Acceptance criteria*. One finding ≈ one commit.
3. Read section 2 (*Context*) first — several fixes depend on facts about ADM that are not obvious from the code.
4. Do **not** test destructive behaviour (stop/unmount/kill paths) on the real NAS without the user being present. Unit-test in a Linux/WSL sandbox first (see the test ideas in each finding).
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

## 4. Suggested implementation order

| # | Finding | Why first |
|---|---|---|
| 1 | **F1** stop path (with `start-stop.sh.old` backup) | Can kill running services today on any MountFix stop/upgrade. |
| 2 | **F2** boot without `jq` | Mounts may silently not happen after reboot. |
| 3 | **F6** shared library | F1/F2/F4/F5 all need the same helpers; do it right after F1/F2 to avoid duplicating fixes. |
| 4 | **F3** mount intent = config | Prevents split-brain together with F2. |
| 5 | **F4** rsync flags + server-side running check | Data integrity of Docker copies. |
| 6 | **F5**, **F7**, **F8** | Hardening and API consistency. |
| 7 | **F9**, **F10**, **F11** | Cleanup, performance, build hygiene. |

After F1+F2 are merged and a package is built, the user should install it on the NAS and perform one controlled reboot to confirm all configured apps are mounted (`grep AppCentral /proc/mounts`) and nothing was killed during shutdown.

---

## 5. What is already good (keep it)

- Mount detection via `stat -c %d:%i` inode/device comparison — more robust than parsing `mount` output.
- Input validation in the webman mount/transfer functions (`validate_app_name`, `validate_target_volume`).
- Atomic config write (`tmp` + `mv`) with backup rotation.
- UI guards (button enable/disable by state, confirmation before overwriting target data, unmount → sync-back flow).
- Correct stop ordering reasoning (`tests/test_start_stop.sh` documents ADM's `sort -r` for `K*` scripts).
- Good documentation baseline (`docs/ARCHITECTURE.md`, `IDEAS.md`).
