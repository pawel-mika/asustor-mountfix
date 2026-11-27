# Third-Party Licenses & Notices

MountFix itself is licensed under the **MIT License** (see [LICENSE](LICENSE)).

MountFix bundles a standalone third-party binary in `bin/iotop-static`, which is executed as an external CLI subprocess by `webman/scripts/diskwatch.sh` (mere aggregation under GPL; MountFix does not link against it).

---

## 1. `iotop-c` (`bin/iotop-static`)

- **Version:** `1.31` (statically linked `x86-64` ELF binary built on Alpine Linux)
- **Upstream Project:** [https://github.com/Tomas-M/iotop](https://github.com/Tomas-M/iotop)
- **Copyright:**
  - Copyright (C) 2014 Vyacheslav Trushkin
  - Copyright (C) 2020–2026 Boian Bonev
- **License:** GNU General Public License, version 2.0 or later (`GPL-2.0-or-later`)
- **Full License Text:** [licenses/GPL-2.0.txt](licenses/GPL-2.0.txt)

### Corresponding Source Code

The unmodified upstream source code for `iotop-c` 1.31 is available at:
- Release tag: [https://github.com/Tomas-M/iotop/releases/tag/v1.31](https://github.com/Tomas-M/iotop/releases/tag/v1.31)
- Source archive: [https://github.com/Tomas-M/iotop/archive/refs/tags/v1.31.tar.gz](https://github.com/Tomas-M/iotop/archive/refs/tags/v1.31.tar.gz)

If you require a copy of the corresponding source code and the upstream archive is unavailable, please contact the MountFix maintainer (`ketonal80@gmail.com`) or open an issue in the MountFix repository.

---

## 2. Statically Linked Libraries in `bin/iotop-static`

The bundled `bin/iotop-static` binary statically links the following open-source libraries:

### `musl` (`1.2.5`)
- **Upstream Project:** [https://musl.libc.org/](https://musl.libc.org/)
- **Source Archive:** [https://musl.libc.org/releases/musl-1.2.5.tar.gz](https://musl.libc.org/releases/musl-1.2.5.tar.gz)
- **Copyright:** Copyright © 2005–2024 Rich Felker, et al.
- **License:** MIT License (same terms as [LICENSE](LICENSE))

### `ncurses`
- **Upstream Project:** [https://invisible-island.net/ncurses/](https://invisible-island.net/ncurses/)
- **Copyright:** Copyright 1998–2024 Thomas E. Dickey; Free Software Foundation, Inc.
- **License:** MIT / X11-style License (same permissive terms as [LICENSE](LICENSE))
