<p align="center"><img width="468" height="85" alt="image" src="https://github.com/user-attachments/assets/bc5c35c0-3913-4e74-9fa6-0eceaa5af266" /></p>

# cline_mod — Cline context/output limits patch

**Unofficial, local, reversible patch for the Cline VS Code extension that raises the
hard-coded truncation limits which silently cut tool output, file reads, web fetch
content and editor payloads.**

Not affiliated with, endorsed by, or supported by Cline. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

---

## Why this exists

Cline truncates content in several places with hard-coded budgets. When a result is
larger than the budget, the model receives placeholder markers instead of data:

```text
...[truncated N chars]...
[Content truncated: showing first 50000 of 62928 characters]
[FILE TRUNCATED: This content is 1.2 MB but only the first 400.0 KB is shown ...]
[... output truncated: 206639 chars total. Refine the command ...]
```

Every truncation costs an extra tool round-trip and makes large files impossible to
edit in one pass. This is upstream issue
[cline/cline#13263](https://github.com/cline/cline/issues/13263). Upstream pull request
[cline/cline#13693](https://github.com/cline/cline/pull/13693) addresses part of it, but
was still open and unmerged at the time of writing, and it deliberately leaves several
*defaults* unchanged.

This repository changes the limits directly in the installed extension bundle:
**numeric constants only, one exact-match anchor per change, automatic backup,
one-command revert.**

## Supported versions

The generated support matrix lives in [docs/supported-versions.md](docs/supported-versions.md);
new Cline releases are picked up automatically (see [docs/automation.md](docs/automation.md)).

| Cline version | Bundle SHA-256 (before patch) | Status |
|---|---|---|
| `4.1.21` | `0035a6327275fd3f750ae7cbabf944f2d31f6f36f53a37a808eff7b0421e2121` | **AUTO** — 15/15 locator rules, 21 edits, `node --check` PASS |

The patcher takes its edit table from [`anchors/anchors.json`](anchors/anchors.json) for the
installed version (falling back to a built-in 4.1.21 table). It refuses to touch any anchor
that is not found exactly once, so an unexpected build fails closed instead of corrupting the
bundle.

## What changes

| # | Limit | Before | After |
|---|---|---|---|
| 1 | `run_commands` output | 48 000 chars | 200 000 |
| 2 | `search_codebase` output | 48 000 | 200 000 |
| 3 | `read_files` output | 48 000 | 200 000 |
| 4 | `read_files` max lines | 2 000 | 20 000 |
| 5 | `read_files` per-line chars (`[line truncated]`) | 2 000 | 20 000 |
| 6 | attached file content (`FILE TRUNCATED`) | 400 KB | 4 MB |
| 7 | `fetch_web_content` content | 50 000 chars | 200 000 |
| 8 | editor `new_text`/`old_text` guard | 6 000 chars | 100 000 |
| 9 | tool-result forwarding cap (the `...[truncated]...` culprit) | 8 000 chars | 300 000 |
| 10 | assistant text / tool-call markup caps | 200 000 / 12 000 | 400 000 / 100 000 |
| 11 | SDK tool budgets (grep, shell tail buffer, glob, traversal) | mixed | raised proportionally |

Full evidence, exact anchor strings and the byte-context used to locate each constant:
[docs/limits-map.md](docs/limits-map.md).

## Automatic updates

[`.github/workflows/detect-new-cline-release.yml`](.github/workflows/detect-new-cline-release.yml)
runs daily at 05:17 UTC (and on demand): it finds the newest Cline release, downloads the VSIX,
extracts `dist/extension.js`, re-derives every anchor edit with
[`tools/cline-limits-tool.mjs`](tools/cline-limits-tool.mjs), verifies them (`old` must be unique,
patched bundle must pass `node --check`) and publishes the updated patch. A fully mapped version
becomes the **latest** release; a partially mapped one is published as a prerelease and an issue
is opened with the rules that need manual review. Details: [docs/automation.md](docs/automation.md).

## Usage

```powershell
# 1. inspect only — shows every anchor, its match count and patch status
pwsh -File scripts/patch_cline_limits.ps1 -Report

# 2. apply (creates a timestamped backup first)
pwsh -File scripts/patch_cline_limits.ps1 -Apply

# 3. in VS Code: Command Palette -> "Developer: Reload Window"
```

Optional parameters: `-ExtensionRoot <path>`, `-ExpectedVersion 4.1.21`, `-Force`.

Backup location: `%USERPROFILE%\.cline-limits-patch\backup\<timestamp>\`
(`extension.js`, `package.json`, `patch-manifest.json` with before/after SHA-256).

### Verify it worked

```powershell
# should now return ~200 000 characters instead of eliding the middle at 48 000
1..400 | ForEach-Object { 'x{0:000}: {1}' -f $_, ('y' * 800) }
```

### Revert

```powershell
pwsh -File scripts/revert_cline_limits.ps1 -List                 # show backups
pwsh -File scripts/revert_cline_limits.ps1                       # restore newest
pwsh -File scripts/revert_cline_limits.ps1 -BackupDir <path>     # restore specific
# strongest reset: reinstall the official build
pwsh -File scripts/revert_cline_limits.ps1 -ReinstallOfficialVsix -VsixPath .\cline-4.1.21.vsix
```

## Risks and caveats

- **Bigger context, bigger cost.** Every tool result is sent to the model, so raising caps
  increases prompt size, token usage, latency and the chance of hitting the model's own
  context window. Edit the numbers in `scripts/patch_cline_limits.ps1` if you prefer
  ~100 000 instead of 200 000.
- **Extension auto-update overwrites the patch.** Disable auto-update for Cline, or re-run
  `-Apply` after an update (re-verify the new build with `-Report` first).
- **Only the installed bundle is touched.** No source build, no signing, no marketplace
  publication. VS Code does not verify the contents of an unpacked extension, so reloading
  the window after patching is enough.
- **Scripts are Windows PowerShell** (5.1+). The patched extension itself is
  cross-platform — the edits are simply made by a local script.
- Provided **as is**, without warranty. Always keep the backup.

## Repository layout

```text
LICENSE                          MIT — applies to this repository's own scripts/docs
THIRD_PARTY_NOTICES.md           upstream licence and attribution facts
NOTICE-UPSTREAM.md               exact provenance: version, hashes, every edit before/after
README.md                        this file
anchors/anchors.json             edit table per Cline version (used by the patcher)
anchors/locators.json            stable detection recipes for each limit
anchors/reports/<version>.json   per-rule detection report (status, reason, evidence)
docs/limits-map.md               limit -> anchor -> before/after, with locating evidence
docs/automation.md               how automatic version detection and releases work
docs/supported-versions.md       generated support matrix
scripts/patch_cline_limits.ps1   report/apply, backup, syntax validation
scripts/revert_cline_limits.ps1  list/restore backups, optional official VSIX reinstall
tools/cline-limits-tool.mjs      detect / verify / render-docs / notes (Node, no deps)
.github/workflows/               validate CI + automatic upstream-release pipeline
```

## Русская справка (кратко)

Патч поднимает жёстко зашитые лимиты обрезки в установленном расширении Cline
**4.1.21**: вывод команд и поиска 48k → 200k символов, чтение файлов 48k → 200k
(строки 2k → 20k, длина строки 2k → 20k), вложенные файлы 400 КБ → 4 МБ,
`fetch_web_content` 50k → 200k, лимит редактора 6k → 100k, главный виновник
маркеров `...[truncated]...` (8k) → 300k. Меняются **только числовые константы** —
по одной точной строке-якорю на каждое изменение; скрипт сначала снимает бэкап и
отказывается работать, если якорь не найден ровно один раз.

Порядок: `-Report` → `-Apply` → Reload Window. Откат — `revert_cline_limits.ps1`
или переустановка официального VSIX. Скрипты — только для Windows PowerShell.
Проект неофициальный, с Cline не связан; исходный код Cline здесь не распространяется.

**Автообновления:** workflow раз в сутки сам находит свежий релиз Cline, заново
определяет каждый лимит (по стабильным маркерам и именам свойств, а не по
минифицированным переменным), проверяет результат `node --check` и публикует релиз
`patch-v<версия>`; полностью распознанная версия становится `latest`, частично
распознанная — prerelease + issue. Таблица версий — `docs/supported-versions.md`,
подробности — `docs/automation.md`.

