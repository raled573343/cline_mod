# Limits map — anchors, defaults and patched values

Evidence table for Cline **4.1.21** (`publisher: saoudrizwan`, `name: claude-dev`,
`displayName: Cline`), single bundle `dist/extension.js` (26 360 724 bytes,
sha256 `0035a632…e2121`).

Every anchor below was required to occur **exactly once** in that bundle. The
`Surrounding code` column quotes the bytes used to confirm that the constant really
belongs to the limit named on the left.

## 1. Tool output budgets

| Limit (what the model sees) | Anchor (symbol) | Before | Patched | Surrounding code / marker |
|---|---|---|---|---|
| `run_commands` output, head+tail elision | `e.maxChars??48e3` | 48 000 | `2e5` | `function O3e(t,e={}){let r=e.maxChars??48e3,…` and `[... output truncated: ${i} chars total. Refine the command (grep, head, tail) …]` |
| `search_codebase` output | `WQt=48e3` | 48 000 | `2e5` | `if(t.length<=WQt)return t` and `[... search output truncated: ${t.length} chars total. …]` |
| `read_files` output chars | `nXo=48e3` | 48 000 | `2e5` | tool description: ``Each read returns at most ${QQt} lines / ~${Math.round(nXo/1024)}k characters`` |
| `read_files` max lines | `QQt=2e3` | 2 000 | `2e4` | same description string; loop guard `d.length>=QQt` |
| `read_files` per-line chars | `jCn=2e3` | 2 000 | `2e4` | `b.length>jCn&&(b=`${b.slice(0,jCn)} [line truncated]`)` |
| tool-result forwarding cap (**source of `...[truncated N chars]...`**) | `e5p` inside the block below | 8 000 | `3e5` | env map directly after: `Nwn={maxToolResultChars:"CLINE_MESSAGE_BUILDER_MAX_TOOL_RESULT_CHARS",…}` |
| attached-file content (`FILE TRUNCATED`) | `function Xku(t,e=409600)` | 409 600 (400 KB) | `4e6` (4 MB) | `…[FILE TRUNCATED: This content is ${…} but only the first ${…} is shown …]` |
| editor `old_text`/`new_text` guard | `E0e=6e3` | 6 000 | `1e5` | `Editor input too large: old_text was ${t.old_text.length} characters, exceeding the recommended limit of ${E0e}` |

## 2. fetch_web_content

`web-fetch.ts` caps the *content* it returns and hard-codes the number again in the notice:

```
A.slice(0,5e4)];return A.length>5e4&&x.push(` [Content truncated: showing first 50000 of ${A.length} characters]`)
```

| Anchor | Before | Patched |
|---|---|---|
| `A.slice(0,5e4)` | 50 000 | `2e5` |
| `A.length>5e4&&` | 50 000 | `2e5` |
| `showing first 50000 of` (notice text) | 50 000 | `200000` |

The network layer's own `maxResponseBytes` default is 5 MB and is left untouched.

## 3. Message builder (context sent to the model)

Single minified assignment block; all values are changed in one edit:

```text
before:  e5p=8e3,t5p=5e4,r5p=6e6,n5p=2e5,i5p=12e3,a5p=65536,jet=2e3,LVo=4e4,o5p=8
after:   e5p=3e5,t5p=2e5,r5p=6e6,n5p=4e5,i5p=1e5,a5p=65536,jet=2e3,LVo=4e4,o5p=8
```

| Symbol | Role (matching upstream issue `#13263` table) | Before | Patched |
|---|---|---|---|
| `e5p` | tool result cap | 8 000 | 300 000 |
| `t5p` | file content cap | 50 000 | 200 000 |
| `r5p` | total text bytes | 6 000 000 | unchanged |
| `n5p` | assistant text cap | 200 000 | 400 000 |
| `i5p` | assistant tool-call markup cap | 12 000 | 100 000 |
| `a5p` | outdated-rewrite threshold | 65 536 | unchanged |
| `jet` | per-item minimum bytes | 2 000 | unchanged |
| `LVo` | auxiliary cap | 40 000 | unchanged |
| `o5p` | auxiliary counter | 8 | unchanged |

Already configurable in 4.1.21 through environment variables (no patch needed):
`CLINE_MESSAGE_BUILDER_MAX_TOOL_RESULT_CHARS`,
`CLINE_MESSAGE_BUILDER_MAX_TOTAL_TEXT_BYTES`,
`CLINE_MESSAGE_BUILDER_MIN_OUTDATED_REWRITE_BYTES` (accepts `disable` / `infinity`).
The nine `CLINE_TOOL_*` variables proposed by upstream PR #13693 **do not exist** in
4.1.21 (`CLINE_TOOL_` occurrence count in the bundle: 0) — that is why this patch edits
defaults instead.

## 4. SDK tool budgets (lazily loaded module)

```text
before:  Suo=102400,Zfo=12e4,Wad=262144,OKe=102400,qad=2e3,Gad=200,Had=40,zad=5e4
after:   Suo=5e5,   Zfo=12e4,Wad=2e6,   OKe=2e5,   qad=2e4, Gad=2e3,Had=100,zad=2e5
```

| Symbol | Role | Before | Patched | Evidence |
|---|---|---|---|---|
| `Suo` | shell stdout tail buffer | 102 400 | 500 000 | `Xt(this,gk,"f").length>Suo&&…slice(length-Suo)` |
| `OKe` | ripgrep/grep output budget | 102 400 | 200 000 | `s.length>OKe&&(c=!0,s=s.slice(0,OKe),n.kill("SIGKILL"))`, `[output truncated at ${OKe} bytes]` |
| `Wad` | default byte-read size | 262 144 | 2 000 000 | `jfo(t){return t===void 0?Wad:t}` |
| `qad` | long-line scan guard | 2 000 | 20 000 | `!(n.length>qad)&&e.test(n)…` |
| `Gad` | glob result count | 200 | 2 000 | `n.slice(0,Gad).map(s=>s.path).join(" ")` |
| `Had` | traversal depth | 40 | 100 | `if(s>Had)return!0` |
| `zad` | traversal entry budget | 50 000 | 200 000 | `async function Uad(t,e,r,i){let a=zad…` |
| `Zfo` | exec timeout (ms, **not** a content limit) | 120 000 | unchanged | `e.exec(i,{timeoutMs:o??Zfo,…})` |

## 5. `run_commands` execution timeout

For `backgroundExec`, Cline has **two independent 30-second defaults**. Both must be
raised; changing only the public `bashTimeoutMs` fallback would simply expose the
inner child-process executor's own 30-second kill timer.

| Layer | Stable locator / source shape | Before | Patched |
|---|---|---:|---:|
| shell-tool wrapper | `config.bashTimeoutMs ?? 30000` / minified `bashTimeoutMs??<literal>` | 30 000 ms | 3 600 000 ms |
| background child-process executor | destructured `timeoutMs = 30000` next to `env = {}` and `combineOutput = true` | 30 000 ms | 3 600 000 ms |

The VS Code **foreground** terminal path already supplies
`VSCODE_FOREGROUND_RUN_COMMANDS_TIMEOUT_MS = 60 * 60 * 1000`, so it is intentionally
left unchanged. The patch only brings the default/background path up to the same one-hour
ceiling.

The existing `Zfo=120000` entry in the lazily loaded SDK budget block is a separate
timeout constant and does not replace either of the two 30-second `run_commands`
deadlines above.

## 6. Optional loop-control profile

Cline 4.1.22 contains two related runtime guards:

| Guard | Upstream | Optional profile | Exact minified anchor |
|---|---:|---:|---|
| repeated identical-call soft warning | 3 | 1 000 000 | `softThreshold:3` |
| repeated identical-call hard stop | 5 | 1 000 000 | `hardThreshold:5` |
| consecutive mistake stop | 6 | 1 000 000 | `maxConsecutiveMistakes??6` |

The repeated-call hard verdict is forwarded to the mistake tracker with
`forceAtLimit: true`. That is why a fifth identical tool call can surface through the UI
as “6 errors in a row”: the mistake counter is forced directly to its configured limit.

These three edits are tagged `group=safety-unlock` and `optional=true`. They are excluded
from the standard profile and have a separate verified output hash:

- standard: `8e6c5ededaec988a89783af4f3c2030f7f0cb3ffbd6563b8511cca68f58c14a2`
- standard + optional group: `df07a61548097a4a9ef5006e140492a4fbb48efdf75512726a7a20265d67f1fe`

Both variants pass `node --check` in automatic detection.

## 7. Deliberately not changed

| Item | Why |
|---|---|
| `hook-factory.ts` `MAX_CONTEXT_MODIFICATION_SIZE = 50000` | the constant name is removed by minification; the marker could not be located unambiguously in 4.1.21, and it only affects user-supplied hook scripts |
| 200-character command preview in the chat UI | display-only, lives in the webview bundle, does not affect executed output |
| model catalog `contextWindow` / `maxTokens` entries | not truncation limits; raise them per-provider in Cline's own settings UI (custom-model overrides) instead |

## 8. Reproducing this map

```powershell
$f = "$env:USERPROFILE\.vscode\extensions\saoudrizwan.claude-dev-4.1.21\dist\extension.js"
$t = [IO.File]::ReadAllText($f)
([regex]::Matches($t, [regex]::Escape('e.maxChars??48e3'))).Count   # -> 1
(Get-FileHash $f -Algorithm SHA256).Hash.ToLower()                  # -> 0035a632…e2121
```

The patch script performs the same uniqueness check for every recorded edit and aborts if any
anchor is missing or ambiguous.
