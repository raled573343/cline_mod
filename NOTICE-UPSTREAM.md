# Upstream provenance and exact change record

This file records *what was changed, in which artifact, and how it was verified*. It is
the "prominent notice of change" required by Apache-2.0 §4(b) if the patched output is
ever redistributed.

## 1. Target artifact

| Item | Value |
|---|---|
| Extension | Cline for VS Code (`claude-dev`), publisher `saoudrizwan` |
| Version | `4.1.21` |
| Install folder (reference machine) | `%USERPROFILE%\.vscode\extensions\saoudrizwan.claude-dev-4.1.21` |
| Patched file | `dist/extension.js` (single minified CommonJS bundle) |
| Size before patch | `26 360 724` bytes |
| SHA-256 before patch | `0035a6327275fd3f750ae7cbabf944f2d31f6f36f53a37a808eff7b0421e2121` |
| SHA-256 after patch (4.1.21 reference run) | `d27e72141dab37b1241509018d14a3283cc3aab53c10290c7457dbe4f443edf9` — also recorded in `patch-manifest.json` next to each backup |

## 2. Upstream release provenance

| Item | Value |
|---|---|
| Repository | https://github.com/cline/cline |
| Licence | Apache-2.0, `Copyright 2026 Cline Bot Inc.` |
| Release tag | `v4.1.21` |
| Tag commit | `787ad1b077d8b697892dc3bfcd42e7c65b88789e` |
| Release asset | `cline-4.1.21.vsix` — 9 185 698 bytes, sha256 `f6506589bb51053730364def09feddb9aefb252d4ed367e6215f93d817c0835a` (downloadable from the release page; recommended rollback source) |
| Related issue | cline/cline#13263 |
| Related (unmerged) PR | cline/cline#13693 |

No upstream source file was copied into this repository. The patch operates on string
literals of size a few dozen characters (`e5p=8e3`, `e.maxChars??48e3`, …) that were
located independently inside the shipped bundle. Those literals are identifiers and
numbers, not creative expression, and are not redistributed here as a work.

## 3. Verification method

1. the bundle was parsed as raw text (`[IO.File]::ReadAllText`);
2. every candidate constant was located with a byte-context window and matched against
   the surrounding code (for example `A.slice(0,5e4)` next to the notice text
   `[Content truncated: showing first 50000 of …]`);
3. each anchor was required to occur **exactly once** in the 26 MB bundle; a duplicate
   would have made the edit unsafe, so such an anchor was rejected;
4. after patching, the patched text is written to a staged file inside the backup folder and
   validated with `node --check` **before** the installed bundle is replaced, so a validation
   failure leaves the live extension untouched.

## 4. Exact edits (before → after)

| # | Area | Anchor before | Anchor after |
|---|---|---|---|
| 1 | `run_commands` output budget | `e.maxChars??48e3` | `e.maxChars??2e5` |
| 2 | `search_codebase` output budget | `WQt=48e3` | `WQt=2e5` |
| 3 | `read_files` output budget | `nXo=48e3` | `nXo=2e5` |
| 4 | `read_files` max lines | `QQt=2e3` | `QQt=2e4` |
| 5 | `read_files` per-line chars | `jCn=2e3` | `jCn=2e4` |
| 6 | attached-file content limit | `function Xku(t,e=409600)` | `function Xku(t,e=4e6)` |
| 7 | web fetch content slice | `A.slice(0,5e4)` | `A.slice(0,2e5)` |
| 8 | web fetch content check | `A.length>5e4&&` | `A.length>2e5&&` |
| 9 | web fetch notice text | `showing first 50000 of` | `showing first 200000 of` |
| 10 | editor payload guard | `E0e=6e3` | `E0e=1e5` |
| 11 | message-builder caps | `e5p=8e3,t5p=5e4,r5p=6e6,n5p=2e5,i5p=12e3,a5p=65536,jet=2e3,LVo=4e4,o5p=8` | `e5p=3e5,t5p=2e5,r5p=6e6,n5p=4e5,i5p=1e5,a5p=65536,jet=2e3,LVo=4e4,o5p=8` |
| 12 | SDK tool budgets | `Suo=102400,Zfo=12e4,Wad=262144,OKe=102400,qad=2e3,Gad=200,Had=40,zad=5e4` | `Suo=5e5,Zfo=12e4,Wad=2e6,OKe=2e5,qad=2e4,Gad=2e3,Had=100,zad=2e5` |

Edit 9 changes a user-visible string only, so the notice text continues to agree with the
enforced value.

Constants left deliberately unchanged: `a5p=65536` (stale-read rewrite threshold — it can
be turned off upstream via `CLINE_MESSAGE_BUILDER_MIN_OUTDATED_REWRITE_BYTES=disable`),
`jet=2e3` (per-item minimum), `r5p=6e6` (total text bytes), `Zfo=12e4` (exec timeout, not a
content limit).

## 5. Date of patch

Patch authored and first applied on the reference machine on 2026-09-27 (see repository
commit history and `patch-manifest.json` timestamps for the exact run).

## 6. Environment note

The patch was prepared on Windows 10/11 with Windows PowerShell 5.1 and Node.js v22 for
syntax validation. VS Code 1.139.1; extension engine requirement `^1.101.0`.
