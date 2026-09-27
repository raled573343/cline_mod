# Third-party notices

## Short version

This repository contains **no Cline source code and no Cline binaries**. It contains a
PowerShell patch script, documentation and a machine-readable table of *literal
identifier/number strings* that the script uses as exact-match anchors inside a file
that already exists on your own machine.

## Upstream project

| Item | Value |
|---|---|
| Project | Cline (`cline/cline`) |
| Purpose here | The extension whose hard-coded limits this tool adjusts locally |
| Licence | Apache License 2.0 |
| Copyright notice (verbatim, from upstream `LICENSE`) | `Copyright 2026 Cline Bot Inc.` |
| Licence text | https://github.com/cline/cline/blob/main/LICENSE (also shipped as `LICENSE.txt` inside the installed extension folder) |

### What Apache-2.0 §4 requires when *redistributing* the Work

If you take the patched output (the modified `dist/extension.js`, or a rebuilt
`.vsix`) and redistribute it, you must:

1. give recipients a copy of the Apache-2.0 licence;
2. carry prominent notices stating that you changed the files (this repository's
   `NOTICE-UPSTREAM.md` records the exact edits and dates);
3. retain all copyright, patent, trademark and attribution notices.

### What Apache-2.0 §6 does *not* grant

> "This License does not grant permission to use the trade names, trademarks,
> service marks, or product names of the Licensor, except as required for
> reasonable and customary use in describing the origin of the Work."

Therefore: this project is named as a *patch for* Cline. It is **not** a Cline
product, fork branding, or official distribution, and it uses no Cline logo or
Cline product name as its own brand.

## Relationship to upstream work

The underlying problem is tracked upstream as issue
[cline/cline#13263](https://github.com/cline/cline/issues/13263) ("Cline truncates
tool output & file content in context ... limits should be configurable"). An
upstream pull request, [cline/cline#13693](https://github.com/cline/cline/pull/13693),
makes several of these limits configurable and raises two defaults. That PR was
still open and unmerged when this patch was written, so this repository solves the
same problem locally **without** applying or copying that PR's code. No code from
that PR is included here; only independently located numeric constants are changed.

## Trademarks

"Cline", "VS Code" and other names are the property of their respective owners and
are used here only to describe interoperability. No endorsement or affiliation is
implied.
