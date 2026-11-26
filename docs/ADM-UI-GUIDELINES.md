# ASUSTOR ADM 5.1.5 ExtJS 4 UI Guidelines

Field-verified constraints and patterns for developing MountFix UI panels (`webman/mf_*.js`) on **ASUSTOR ADM 5.1.5** (ExtJS 4.0.7 + ADM `launcherBuild.js` + `adm3.css`).

> **Rule for contributors & agents:** Read this document before modifying any `webman/mf_*.js` file. Do not guess ExtJS 4 behavior under ADM — ADM overrides several standard ExtJS window, layout, AJAX, and CSS rules globally.

---

## 1. Main Application Window (`AS.ARC.appWindow`)

- **Titlebar `?` / extra buttons — use `exTitleButtons`, never `tools`:**
  - `AS.ARC.appWindow` constructs header tools via `createExtraHeaderButtonsConfig(cfg)`. Passing `tools` directly to `desktop.createWindow()` bypasses ADM's inner-`<img>` class injection.
  - Pass `exTitleButtons: [{ cls: 'x-tool-question', tooltip: '...', handler: fn }]` and **do not** attach custom `listeners` to individual `exTitleButtons` items (ADM overwrites them).
- **Window lifecycle listeners — attach via `this.win.on(...)` after creation:**
  - `AS.ARC.appWindow.constructor` runs `Ext.apply(this, cfg)` before `callParent()`. Passing `listeners: { ... }` inside `desktop.createWindow()` silently overwrites ADM's prototype `beforerender`, `afterrender` (PerfectScrollbar on `.x-panel-body` + click-to-focus), and `resize` (`Ps.update`) handlers.
  - Always attach `afterrender` / `beforeclose` via `this.win.on(...)` *after* `desktop.createWindow()` returns. Never call `Ps.initialize(win.body.dom)` manually.
- **Window title:** Do not call `win.setTitle(...)` after creation (can break ADM header icon layout). Display version strings in the footer toolbar (`#displayVersion`).

---

## 2. Dialogs (`AS.ARC.subWindow` vs. `AS.ARC.msgWindow`)

- **`AS.ARC.msgWindow`:** Use only for short, fixed-height confirmations or warnings (it fixes its inner panel to `height - 96` without scrolling). Pass content via `asItems: [{ xtype: 'displayfield', value: html }]` and buttons via `fbar`.
- **`AS.ARC.subWindow`:** Use for scrollable or richer modals (*MountFix Quick Guide*, *Delete Target Copy*).
  - Always set `layout: 'fit'` on `AS.ARC.subWindow` with **one** single inner `xtype: 'panel'` (`border: false`, `autoScroll: true`, `bodyPadding: '12 16'`).
  - **Do not** set `layout: 'vbox'` directly on `AS.ARC.subWindow` with multiple child items — ADM's subWindow body sizing pushes secondary children down into/behind the `fbar` button row.
  - Never attach `listeners` directly in the `AS.ARC.subWindow` config object if you only need DOM wiring; attach `afterrender` on the inner `panel` instead.

---

## 3. Checkboxes, Inputs & `adm3.css` Global Overrides

ADM's global stylesheet (`/portal/resources/css/adm3.css`) applies an **unscoped** hide rule to every native HTML checkbox on the page:

```css
input[type="checkbox"] { display: none; }
input[type="checkbox"] + label span {
  display: inline-block; width: 16px; height: 16px;
  background-image: url(../images/theme/theme_<color>/ui_form_checkbox.png);
}
input[type="checkbox"]:checked + label span { background-position: 0 -16px; }
```

Use one of these two verified patterns — **never** nest `<input type="checkbox">` inside `<label>`:

1. **Inside `AS.ARC.formBase` (`.as-page-panel`):** Use ExtJS `xtype: 'checkbox'` / `xtype: 'checkboxfield'` (e.g. `#chkSysctlTuning`). ExtJS 4 renders `<input type="button" class="x-form-field x-form-checkbox">`, which bypasses `input[type="checkbox"] { display: none; }` and automatically uses ADM's themed checkbox sprite.
2. **Inside raw HTML panels (e.g. `AS.ARC.subWindow` `html`):** Use ADM's exact sibling structure so `adm3.css` renders the native 16×16 themed checkbox sprite (Blue/Green/Orange):
   ```html
   <input type="checkbox" id="my-chk-id">
   <label for="my-chk-id" style="display:flex; align-items:center; gap:8px; cursor:pointer;">
     <span style="flex-shrink:0;"></span>
     <div>Checkbox label text here</div>
   </label>
   ```
   - **Critical:** Keep **only one** empty `<span></span>` inside `<label>` for the sprite. Wrap the label text in a `<div>` (not a `<span>`), otherwise `input[type="checkbox"] + label span` shrinks the text element to `16px × 16px`.

---

## 4. Forms, Grids & Fieldsets

- **Grid inside `fieldset` with `layout: 'fit'`:** ExtJS 4 does not subtract the `<legend>` height (~28px), which clips the last row. Always add `padding: '0 0 28 0'` to the grid.
- **Selectable rows for running apps:** Never apply `x-item-disabled` via `viewConfig.getRowClass` on rows that still need to be selectable (it blocks click events). Use a custom CSS class (`mf-app-running`) instead.
- **Combo store reload without re-triggering `change`:** Wrap `store.loadData(...)` + `setValue(...)` with `combo.suspendEvents()` / `combo.resumeEvents()` so refreshing volume free space does not trigger a redundant full `validate()`.

---

## 5. AJAX & Polling (`AS.ARC.ajax`)

- **Always set `enableFailureReturn: true`:** On HTTP 5xx, network drops, or timeouts, ADM's `AS.ARC.ajax` skips the caller's `failure` callback unless `enableFailureReturn: true` is set, leaving `maskStack` overlays stuck permanently.
- **Error payload location:** When a CGI returns HTTP 200 with top-level `"success": false`, ADM routes it to `failure(json)` (not `success`). Always inspect `(json && json.result && json.result.error) || (json && json.error)`.
- **Polling:** Use chained `setTimeout` (never overlapping `setInterval`) and always cancel active timers in `this.win.on('beforeclose', ...)`.
- **Non-blocking validation:** Track in-flight `validate()` requests via `_validatingCount` and disable action buttons while `_validatingCount > 0` instead of masking the whole window.

---

## 6. Local ADM Reference Cache (Optional, Gitignored)

Proprietary ASUSTOR files (`adm3.css`, `launcherBuild.js`) must **never** be committed to this repository. For local offline inspection, place read-only copies under `.adm-ref/` (listed in `.gitignore`) so CSS/ExtJS rules can be grepped locally without opening Chrome DevTools.
