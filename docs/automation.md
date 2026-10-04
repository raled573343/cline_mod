# Automatic updates

The repository watches upstream Cline releases and regenerates the patch for each new
build. Everything runs in [`.github/workflows/detect-new-cline-release.yml`](../.github/workflows/detect-new-cline-release.yml).

## Why it works without a human in the loop

The bundle is minified, so variable names (`e5p`, `WQt`, `jCn`, …) change between builds
and cannot be used as anchors. [`anchors/locators.json`](../anchors/locators.json) instead
describes every limit as a *recipe* built from strings that survive minification:

| Anchor kind | Example | Why it is stable |
|---|---|---|
| property name | `maxToolResultChars=Iet(e.maxToolResultChars,<SYM>)` | property names are not mangled |
| environment variable name | `CLINE_MESSAGE_BUILDER_MAX_TOOL_RESULT_CHARS` | user-visible API |
| tool-description text | `at most ${<SYM>} lines` | shipped to the model verbatim |
| truncation notice text | `[Content truncated: showing first`, `[line truncated]`, `search output truncated` | user-visible |
| frozen value signature | the comma-run `102400,12e4,262144,102400,2e3,200,40,5e4` | matched positionally |
| stable timeout property/shape | `bashTimeoutMs??<literal>` and the `timeoutMs/env/combineOutput` destructuring sequence | survives minification while local symbols change |

`node tools/cline-limits-tool.mjs detect` resolves each recipe, builds the `old → new`
edit pair, applies all edits to an in-memory copy, requires every `old` to occur exactly
once, and finally runs `node --check` on the result. Only then are the anchors recorded.

## Pipeline

```text
cron 05:17 UTC  or  manual dispatch (optional forced version)
        |
        v
resolve latest cline/cline release  ->  skip if already in anchors/anchors.json
        |
        v
download cline-<version>.vsix  ->  extract extension/dist/extension.js  ->  sha256
        |
        v
node tools/cline-limits-tool.mjs detect   (17 locator rules, uniqueness + node --check)
        |
        +--> status AUTO    -> commit anchors + docs, publish release patch-v<version> as LATEST
        |
        +--> status REVIEW  -> commit anchors, publish prerelease patch-v<version>-review,
                               open an issue listing the rules that need manual mapping
        |
        v
release assets: patch/revert scripts, anchors.json, REPORT-<version>.json,
                SUPPORTED-VERSIONS.md, RELEASE-NOTES.md, SHA256SUMS.txt
```

## Release semantics

- A fully detected version is published with `gh release create --latest`, so `latest`
  always points at the newest **fully supported** Cline version.
- A partial detection is published with `--prerelease`, which never becomes `latest`;
  the previous good release stays `latest` until a rule is refreshed.
- Each release carries the patcher, the anchors for every supported version, the full
  detection report and checksums. No Cline source code or binaries are redistributed.

## Operating it

| Task | How |
|---|---|
| Check for a new version now | Actions → `detect-new-cline-release` → Run workflow (leave `version` empty) |
| Add a specific version | Run workflow with `version: 4.1.22` |
| Dry run (no commit, no release) | Run workflow with `dry_run` enabled |
| Reproduce locally | `node tools/cline-limits-tool.mjs detect --bundle <extension.js> --version <x.y.z>` |
| Re-check a recorded version | `node tools/cline-limits-tool.mjs verify --bundle <extension.js> --version <x.y.z>` |
| Refresh the docs table | `node tools/cline-limits-tool.mjs render-docs` |

## When a rule reports `REVIEW`

Upstream changed more than a value: the recipe no longer matches. The workflow commits the
partial anchors, publishes a prerelease and opens an issue containing the exact reason and
the evidence captured from the new build. To fix it:

1. open the issue's attached report (`anchors/reports/<version>.json`), which lists every
   rule with its status, reason and matched text;
2. update the failing entry in `anchors/locators.json` (adjust the pattern or the
   `signature`/`targets` pair for the block rule);
3. lock in the values for that build:
   `node tools/cline-limits-tool.mjs detect --bundle extension.js --version <x.y.z>`
   until it reports `AUTO`;
4. commit. The workflow republishes on the next run (or rerun it manually).

## Safety properties

- Anchors are applied only when each `old` string is unique in the bundle; otherwise the
  patcher refuses to write.
- When a locator refresh changes the canonical patched SHA for the same clean upstream bundle,
  the previous canonical patched SHA is retained in `acceptedSourceHashes`. This enables a
  fail-closed in-place upgrade: the hash must be trusted, all anchors must be `READY` or
  `ALREADY_PATCHED`, and only `READY` edits are applied.
- The patched text is validated with `node --check` **before** the live bundle is replaced.
- Every patch creates a timestamped backup (`extension.js`, `package.json`,
  `patch-manifest.json` with before/after hashes) and `revert_cline_limits.ps1` restores it.
- `-Report` never writes; `-Apply` re-verifies the recorded pre-patch SHA-256 and warns when
  a same-version rebuild no longer matches it.
- A change to `anchors/locators.json` automatically re-detects the newest already-supported
  Cline build. Existing-version refreshes are accepted only when every locator still resolves
  to `AUTO`; otherwise the workflow fails before overwriting the recorded good anchors.
