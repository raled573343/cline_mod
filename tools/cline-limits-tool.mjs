#!/usr/bin/env node
/**
 * cline-limits-tool — detection / verification / docs for the Cline limits patch.
 *
 * Subcommands
 *   detect      resolve every locator rule against a bundle, build the anchor edits,
 *               validate them (uniqueness + `node --check`), record hashes and reports
 *   verify      re-apply a recorded anchor entry to a bundle and recompute hashes
 *   render-docs regenerate docs/supported-versions.md from anchors/anchors.json
 *   standalone  render a one-file patcher with one version embedded
 *
 * The tool is dependency-free (Node 18+). Patching itself stays in
 * scripts/patch_cline_limits.ps1, which reads the same anchors/anchors.json.
 */
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";

const RULES_FILE = "anchors/locators.json";
const ANCHORS_FILE = "anchors/anchors.json";
const REPORTS_DIR = "anchors/reports";
const DOCS_FILE = "docs/supported-versions.md";

// ---------------------------------------------------------------- utilities

function sha256(text) {
	return createHash("sha256").update(text, "utf8").digest("hex");
}

function readJson(file) {
	return JSON.parse(fs.readFileSync(file, "utf8"));
}

function writeJson(file, value) {
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function makeRegex(pattern, flags = "g") {
	return new RegExp(pattern, flags);
}

function findAll(text, pattern) {
	const matches = [];
	const re = makeRegex(pattern);
	let m;
	while ((m = re.exec(text)) !== null) {
		matches.push({ index: m.index, text: m[0], groups: m.slice(1) });
		if (m.index === re.lastIndex) re.lastIndex += 1;
	}
	return matches;
}

function short(text, width = 90) {
	const flat = text.replace(/\s+/g, " ");
	return flat.length <= width ? flat : `${flat.slice(0, width)}…`;
}

// ------------------------------------------------------------ rule resolution

/**
 * Resolve one locator rule against the bundle text.
 * Returns { status, reason, evidence, edits: [{ old, new }] }.
 *
 * Rule kinds
 *   literal      : a single capture group yields the numeric literal; the whole
 *                  match is rewritten so the replacement stays unique
 *   symbol-decl  : capture a variable name, then rewrite `SYM=<value>` at its
 *                  declaration site
 *   block-signature : locate a comma-run of assignments whose values match a frozen
 *                  signature, then rewrite the listed positions positionally
 */
function resolveRule(rule, bundle) {
	const steps = rule.steps ?? [];

	if (rule.kind === "literal" || rule.kind === "symbol-decl") {
		let scope = bundle;
		let scopeNote = "bundle";

		for (const step of steps) {
			if (step.type === "marker") {
				const hits = findAll(scope, step.pattern);
				if (hits.length !== 1) {
					return { status: "REVIEW", reason: `marker '${short(step.pattern)}' matched ${hits.length} times`, evidence: null };
				}
				const hit = hits[0];
				const from = Math.max(0, hit.index - (step.before ?? 0));
				const to = Math.min(scope.length, hit.index + hit.text.length + (step.after ?? 0));
				scope = scope.slice(from, to);
				scopeNote = `window(${step.before ?? 0},${step.after ?? 0})`;
				continue;
			}
			if (step.type !== "capture") continue;

			const pattern = (step.pattern ?? "").replaceAll("$symbol", rule.__symbol ?? "");
			const hits = findAll(scope, pattern);
			if (hits.length !== 1) {
				return { status: "REVIEW", reason: `capture '${short(pattern)}' matched ${hits.length} times in ${scopeNote}`, evidence: null };
			}
			const value = hits[0].groups[(step.valueGroup ?? 1) - 1];
			if (value === undefined) {
				return { status: "REVIEW", reason: `capture group ${step.valueGroup ?? 1} missing in '${short(pattern)}'`, evidence: null };
			}
			if (step.as === "symbol") {
				rule.__symbol = value;
			} else {
				rule.__value = value;
				rule.__match = hits[0].text;
			}
		}

		if (rule.kind === "literal") {
			if (!rule.__match || rule.__value === undefined) {
				return { status: "REVIEW", reason: "no literal captured", evidence: null };
			}
			const target = String(rule.target);
			return {
				status: "AUTO",
				reason: `literal ${rule.__value} -> ${target}`,
				evidence: short(rule.__match, 140),
				edits: [{ old: rule.__match, new: rule.__match.replace(rule.__value, target) }],
			};
		}

		if (!rule.__symbol) {
			return { status: "REVIEW", reason: "no symbol captured", evidence: null };
		}
		// Minified symbols may start with `$`, which is a regex anchor, so escape the name and
		// locate the declaration with a lookbehind instead of `\b`.
		const symbolPattern = rule.__symbol.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
		const declPattern = `(?<![A-Za-z0-9_$])${symbolPattern}=([0-9]+(?:\\.[0-9]+)?e[0-9]+|[0-9]+)`;
		const decl = findAll(bundle, declPattern);
		if (decl.length !== 1) {
			return { status: "REVIEW", reason: `declaration of ${rule.__symbol} matched ${decl.length} times`, evidence: null };
		}
		const value = decl[0].groups[0];
		const target = String(rule.target);
		return {
			status: "AUTO",
			reason: `${rule.__symbol}: ${value} -> ${target}`,
			evidence: short(decl[0].text, 140),
			edits: [{ old: decl[0].text, new: decl[0].text.replace(value, target) }],
		};
	}

	if (rule.kind === "block-signature") {
		const runs = findAll(bundle, rule.blockPattern);
		const candidates = runs
			.map((run) => {
				const assignments = findAll(run.text, "([A-Za-z0-9_$]+)=([0-9]+(?:\\.[0-9]+)?e[0-9]+|[0-9]+)");
				return { run, assignments, values: assignments.map((a) => Number(a.groups[1])) };
			})
			.filter((c) => c.values.length === rule.signature.length && c.values.every((v, i) => v === rule.signature[i]));

		if (candidates.length !== 1) {
			return {
				status: "REVIEW",
				reason: `block signature matched ${candidates.length} runs (expected 1); defaults may have changed`,
				evidence: rule.signature.join(","),
			};
		}

		const edits = [];
		const detail = [];
		candidates[0].assignments.forEach((assignment, index) => {
			const target = rule.targets[index];
			if (target === null || target === undefined) return;
			const current = Number(assignment.groups[1]);
			if (current === target) return;
			// Include a trailing comma when the assignment is followed by one, so that an old
			// anchor can never match inside its own replacement (e.g. `Gad=200` in `Gad=2000`).
			const after = candidates[0].run.text[assignment.index + assignment.text.length] === "," ? "," : "";
			const oldText = assignment.text + after;
			edits.push({
				old: oldText,
				new: `${assignment.text.replace(assignment.groups[1], String(target))}${after}`,
			});
			detail.push(`${assignment.groups[0]}:${current}->${target}`);
		});
		return {
			status: "AUTO",
			reason: detail.join(", ") || "nothing to change",
			evidence: short(candidates[0].run.text, 140),
			edits,
		};
	}

	return { status: "REVIEW", reason: `unknown rule kind '${rule.kind}'`, evidence: null };
}

// ---------------------------------------------------------------- commands

function applyEdits(bundle, edits) {
	let out = bundle;
	for (const edit of edits) {
		const count = out.split(edit.old).length - 1;
		if (count !== 1) {
			return { ok: false, reason: `edit '${short(edit.old, 60)}' matched ${count} times in the bundle` };
		}
		out = out.replace(edit.old, edit.new);
	}
	return { ok: true, text: out };
}

function nodeCheck(text) {
	const tmp = path.join(os.tmpdir(), `cline-limits-${process.pid}-${Date.now()}.js`);
	fs.writeFileSync(tmp, text, "utf8");
	try {
		execFileSync(process.execPath, ["--check", tmp], { stdio: "pipe" });
		return { ok: true };
	} catch (error) {
		const detail = error.stderr ? error.stderr.toString("utf8") : String(error.message);
		return { ok: false, reason: detail.trim().slice(0, 400) };
	} finally {
		try {
			fs.unlinkSync(tmp);
		} catch {
			/* best effort */
		}
	}
}

function parseArgs(argv) {
	const args = { _: [] };
	for (let i = 0; i < argv.length; i += 1) {
		const token = argv[i];
		if (token.startsWith("--")) {
			const key = token.slice(2);
			const next = argv[i + 1];
			if (next === undefined || next.startsWith("--")) {
				args[key] = true;
			} else {
				args[key] = next;
				i += 1;
			}
		} else {
			args._.push(token);
		}
	}
	return args;
}

function detectGeometry(buf) {
	return {
		bundleBytes: buf.length,
		bundleSha256: createHash("sha256").update(buf).digest("hex"),
	};
}

function cmdDetect(args, repoRoot) {
	const version = args.version;
	const bundlePath = args.bundle;
	if (!version || typeof version !== "string") throw new Error("detect: --version is required");
	if (!bundlePath || typeof bundlePath !== "string") throw new Error("detect: --bundle is required");

	const bundleBuffer = fs.readFileSync(bundlePath);
	const bundle = bundleBuffer.toString("utf8");
	const before = detectGeometry(bundleBuffer);

	const rules = readJson(path.join(repoRoot, RULES_FILE)).rules;
	const results = [];
	const edits = [];

	for (const rule of rules) {
		const scratch = { ...rule };
		const resolved = resolveRule(scratch, bundle);
		results.push({
			key: rule.key,
			area: rule.area,
			kind: rule.kind,
			target: rule.target ?? null,
			status: resolved.status,
			reason: resolved.reason,
			evidence: resolved.evidence,
		});
		if (resolved.status === "AUTO" && Array.isArray(resolved.edits)) edits.push(...resolved.edits);
	}

	const review = results.filter((r) => r.status !== "AUTO");
	const applied = applyEdits(bundle, edits);
	const syntax = applied.ok ? nodeCheck(applied.text) : { ok: false, reason: applied.reason };
	const after = applied.ok ? detectGeometry(Buffer.from(applied.text, "utf8")) : { bundleBytes: null, bundleSha256: null };

	const report = {
		version,
		upstreamTag: typeof args["upstream-tag"] === "string" ? args["upstream-tag"] : null,
		detectedAt: new Date().toISOString(),
		status: review.length === 0 && applied.ok && syntax.ok ? "AUTO" : "REVIEW",
		ruleCount: results.length,
		autoCount: results.length - review.length,
		bundleBytesBefore: before.bundleBytes,
		bundleSha256Before: before.bundleSha256,
		bundleBytesAfter: after.bundleBytes,
		bundleSha256After: after.bundleSha256,
		applyCheck: applied.ok ? "PASS" : `FAIL: ${applied.reason}`,
		syntaxCheck: syntax.ok ? "PASS" : `FAIL: ${syntax.reason}`,
		rules: results,
		edits,
	};

	if (args["dry-run"]) {
		process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
		return report.status === "AUTO" ? 0 : 5;
	}

	const anchorsPath = path.join(repoRoot, ANCHORS_FILE);
	const anchors = readJson(anchorsPath);
	anchors.versions = anchors.versions ?? {};
	const previousEntry = anchors.versions[version];
	const sameCleanBundle = previousEntry?.bundleSha256Before === report.bundleSha256Before;
	const acceptedSourceHashes = new Set(
		sameCleanBundle && Array.isArray(previousEntry?.acceptedSourceHashes)
			? previousEntry.acceptedSourceHashes
			: [],
	);
	if (
		sameCleanBundle &&
		["AUTO", "VERIFIED"].includes(previousEntry?.status) &&
		previousEntry?.bundleSha256After &&
		previousEntry.bundleSha256After !== report.bundleSha256After
	) {
		acceptedSourceHashes.add(previousEntry.bundleSha256After);
	}
	acceptedSourceHashes.delete(report.bundleSha256Before);
	acceptedSourceHashes.delete(report.bundleSha256After);
	const normalizedAcceptedSourceHashes = [...acceptedSourceHashes]
		.map((hash) => String(hash).toLowerCase())
		.filter((hash) => /^[0-9a-f]{64}$/.test(hash))
		.sort();
	if (normalizedAcceptedSourceHashes.length > 0) {
		report.acceptedSourceHashes = normalizedAcceptedSourceHashes;
	}
	anchors.versions[version] = {
		status: report.status,
		method: "detected",
		upstreamTag: report.upstreamTag,
		detectedAt: report.detectedAt,
		bundleBytesBefore: report.bundleBytesBefore,
		bundleSha256Before: report.bundleSha256Before,
		bundleBytesAfter: report.bundleBytesAfter,
		bundleSha256After: report.bundleSha256After,
		applyCheck: report.applyCheck,
		syntaxCheck: report.syntaxCheck,
		...(normalizedAcceptedSourceHashes.length > 0
			? { acceptedSourceHashes: normalizedAcceptedSourceHashes }
			: {}),
		edits: report.edits,
	};
	anchors.updatedAt = report.detectedAt;
	writeJson(anchorsPath, anchors);
	writeJson(path.join(repoRoot, REPORTS_DIR, `${version}.json`), report);

	process.stdout.write(
		`${version}: status=${report.status} rules=${report.autoCount}/${report.ruleCount} ` +
			`edits=${report.edits.length} apply=${report.applyCheck} syntax=${report.syntaxCheck}\n`,
	);
	for (const rule of results.filter((r) => r.status !== "AUTO")) {
		process.stdout.write(`  REVIEW ${rule.key}: ${rule.reason}\n`);
	}
	return report.status === "AUTO" ? 0 : 5;
}

function cmdVerify(args, repoRoot) {
	const version = args.version;
	const bundlePath = args.bundle;
	if (!version) throw new Error("verify: --version is required");
	if (!bundlePath) throw new Error("verify: --bundle is required");

	const bundleBuffer = fs.readFileSync(bundlePath);
	const entry = readJson(path.join(repoRoot, ANCHORS_FILE)).versions?.[version];
	if (!entry) throw new Error(`verify: version ${version} is not recorded in ${ANCHORS_FILE}`);

	const before = detectGeometry(bundleBuffer);
	const applied = applyEdits(bundleBuffer.toString("utf8"), entry.edits ?? []);
	const syntax = applied.ok ? nodeCheck(applied.text) : { ok: false, reason: applied.reason };
	const after = applied.ok ? detectGeometry(Buffer.from(applied.text, "utf8")) : { bundleSha256: null };

	const hashOk = entry.bundleSha256Before ? entry.bundleSha256Before === before.bundleSha256 : null;
	const patchedOk = entry.bundleSha256After ? entry.bundleSha256After === after.bundleSha256 : null;

	process.stdout.write(
		`${version}: hash=${hashOk === null ? "unrecorded" : hashOk} patchedHash=${patchedOk === null ? "unrecorded" : patchedOk} ` +
			`syntax=${syntax.ok ? "PASS" : `FAIL: ${syntax.reason}`}\n`,
	);
	return applied.ok && syntax.ok && hashOk !== false ? 0 : 6;
}

function cmdRenderDocs(args, repoRoot) {
	const anchors = readJson(path.join(repoRoot, ANCHORS_FILE));
	const versions = Object.entries(anchors.versions ?? {}).sort((a, b) => a[0].localeCompare(b[0], undefined, { numeric: true }));

	const lines = [
		"<!-- generated by tools/cline-limits-tool.mjs render-docs -->",
		"",
		"# Supported Cline versions",
		"",
		"Generated from [`anchors/anchors.json`](../anchors/anchors.json). Run",
		"`node tools/cline-limits-tool.mjs render-docs` after the anchors change.",
		"",
		"| Cline version | Anchors | Status | Bundle SHA-256 (before) | Patched SHA-256 | Edits | Detected |",
		"|---|---|---|---|---|---:|---|",
	];
	for (const [version, entry] of versions) {
		lines.push(
			`| \`${version}\` | ${entry.status === "VERIFIED" ? "manual" : "auto-detected"} | ${entry.status} | ` +
				`\`${short(entry.bundleSha256Before ?? "unknown", 16)}\` | \`${short(entry.bundleSha256After ?? "unknown", 16)}\` | ` +
				`${(entry.edits ?? []).length} | ${entry.detectedAt ?? "unknown"} |`,
		);
	}
	lines.push(
		"",
		"`AUTO` means every locator rule resolved and the patched bundle passed `node --check`.",
		"`REVIEW` means at least one rule could not be located in that build - the published anchors",
		"for that version are partial and the repository opens an issue with the details.",
		"`VERIFIED` marks the manually verified reference build.",
		"",
	);

	const target = path.join(repoRoot, DOCS_FILE);
	fs.mkdirSync(path.dirname(target), { recursive: true });
	fs.writeFileSync(target, `${lines.join("\n")}\n`, "utf8");
	process.stdout.write(`wrote ${DOCS_FILE} (${versions.length} version(s))\n`);
	return 0;
}

function cmdStandalone(args, repoRoot) {
	const version = args.version;
	const output = args.output;
	if (!version) throw new Error("standalone: --version is required");
	if (!output) throw new Error("standalone: --output is required");

	const anchors = readJson(path.join(repoRoot, ANCHORS_FILE));
	const entry = anchors.versions?.[version];
	if (!entry) throw new Error(`standalone: version ${version} is not recorded in ${ANCHORS_FILE}`);
	if (!["AUTO", "VERIFIED"].includes(entry.status)) {
		throw new Error(`standalone: version ${version} has status ${entry.status}; refusing to publish installer`);
	}

	const templatePath = path.join(repoRoot, "scripts/patch_cline_limits.ps1");
	let template = fs.readFileSync(templatePath, "utf8");
	const begin = "# BEGIN EMBEDDED_ANCHORS";
	const end = "# END EMBEDDED_ANCHORS";
	const start = template.indexOf(begin);
	const finish = template.indexOf(end);
	if (start < 0 || finish < 0 || finish <= start) {
		throw new Error("standalone: embedded-anchor markers not found in patcher template");
	}

	const catalog = { schema: "cline-mod-standalone-v1", versions: { [version]: entry } };
	const json = JSON.stringify(catalog, null, 2);
	const block = begin + "\n$script:EmbeddedAnchorsJson = @'\n" + json + "\n'@\n" + end;
	template = template.slice(0, start) + block + template.slice(finish + end.length);

	const target = path.resolve(output);
	fs.mkdirSync(path.dirname(target), { recursive: true });
	fs.writeFileSync(target, template, "utf8");
	process.stdout.write(`wrote ${target} (standalone Cline ${version}, ${(entry.edits ?? []).length} edits)\n`);
	return 0;
}
function cmdNotes(args, repoRoot) {
	const version = args.version;
	if (!version) throw new Error("notes: --version is required");

	const reportPath = path.join(repoRoot, REPORTS_DIR, `${version}.json`);
	const anchors = readJson(path.join(repoRoot, ANCHORS_FILE));
	const entry = anchors.versions?.[version];
	if (!entry && !fs.existsSync(reportPath)) throw new Error(`notes: no anchors or report for ${version}`);
	const report = fs.existsSync(reportPath) ? readJson(reportPath) : null;

	const editCount = (entry?.edits ?? report?.edits ?? []).length;
	const rules = report?.rules ?? [];
	const auto = rules.filter((r) => r.status === "AUTO").length;
	const review = rules.filter((r) => r.status !== "AUTO");

	const lines = [
		`# Patch for Cline ${version}`,
		"",
		`Auto-detected anchor updates for Cline \`${version}\`: **${auto}/${rules.length || "?"} locator rules resolved**, ` +
			`**${editCount} edits**, apply check \`${entry?.applyCheck ?? report?.applyCheck ?? "n/a"}\`, ` +
			`syntax check \`${entry?.syntaxCheck ?? report?.syntaxCheck ?? "n/a"}\`.`,
		"",
		"| Bundle SHA-256 | Value |",
		"|---|---|",
		`| before patch | \`${entry?.bundleSha256Before ?? report?.bundleSha256Before ?? "unknown"}\` |`,
		`| after patch | \`${entry?.bundleSha256After ?? report?.bundleSha256After ?? "unknown"}\` |`,
		"",
		"## Downloads in this release",
		"",
		"- `patch_cline_limits.ps1` — self-contained one-file interactive patcher (Windows PowerShell 5.1+)",
		"- `revert_cline_limits.ps1` — rollback utility",
		"- `anchors.json` — detection/audit data; not required to install the patch",
		`- \`REPORT-${version}.json\` — full detection report (per-rule status, evidence, hashes)`,
		"- `SUPPORTED-VERSIONS.md` — generated support matrix",
		"- `SHA256SUMS.txt` — checksums of the assets above",
		"",
		"## Install",
		"",
		"Download only `patch_cline_limits.ps1`, then run:",
		"",
		"```powershell",
		".\\patch_cline_limits.ps1",
		"```",
		"",
		"It reports the installed build first and asks `Apply patch now? [Y/N]` only when every safety gate passes.",
		"If Windows execution policy blocks scripts:",
		"",
		"```powershell",
		"powershell -ExecutionPolicy Bypass -File .\\patch_cline_limits.ps1",
		"```",
		"",
		"Optional non-interactive modes: `.\\patch_cline_limits.ps1 -Report` and `.\\patch_cline_limits.ps1 -Apply`.",
		"After patching: VS Code -> Command Palette -> \"Developer: Reload Window\".",
		"",
	];

	const commandTimeoutPatched = ["bash_tool_timeout", "background_shell_timeout"].every((key) =>
		rules.some((rule) => rule.key === key && rule.status === "AUTO"),
	);
	if (commandTimeoutPatched) {
		lines.push(
			"## Command execution timeout",
			"",
			"- background/default `run_commands`: **30 seconds -> 1 hour** at both the shell-tool wrapper and child-process executor layers",
			"- VS Code foreground terminal already uses a 1-hour timeout upstream and is left unchanged",
			"",
		);
	}
	const upgradeHashes = entry?.acceptedSourceHashes ?? [];
	if (upgradeHashes.length > 0) {
		lines.push(
			"## In-place upgrade",
			"",
			`This patcher recognizes **${upgradeHashes.length} trusted previous patched bundle hash(es)** for Cline \`${version}\`.`,
			"If an older cline_mod patch is already installed, it verifies that hash plus every anchor state, applies only the missing edits, and still requires the final canonical patched SHA-256.",
			"",
		);
	}

	if (review.length > 0) {
		lines.push(
			`## Unresolved rules (${review.length})`,
			"",
			"This build could not be fully mapped automatically. The edits below are **not** applied;",
			"the remaining anchors still work.",
			"",
			"| Rule | Reason |",
			"|---|---|",
		);
		for (const rule of review) lines.push(`| \`${rule.key}\` | ${String(rule.reason).replaceAll("|", "\\|")} |`);
		lines.push("");
	}

	lines.push(
		"Unofficial patch. Not affiliated with Cline. Upstream Cline is Apache-2.0",
		"(`Copyright 2026 Cline Bot Inc.`); this release contains no Cline source or binaries.",
		"",
	);

	process.stdout.write(`${lines.join("\n")}\n`);
	return 0;
}

function main() {
	const args = parseArgs(process.argv.slice(2));
	const command = args._[0];
	const repoRoot = path.resolve(args["repo-root"] ?? process.cwd());

	try {
		switch (command) {
			case "detect":
				return cmdDetect(args, repoRoot);
			case "verify":
				return cmdVerify(args, repoRoot);
			case "render-docs":
				return cmdRenderDocs(args, repoRoot);
			case "standalone":
				return cmdStandalone(args, repoRoot);
			case "notes":
				return cmdNotes(args, repoRoot);
			default:
				process.stderr.write(
					"usage: cline-limits-tool.mjs <detect|verify|render-docs|standalone|notes> [options]\n" +
						"  detect --bundle <extension.js> --version <x.y.z> [--dry-run] [--repo-root <dir>]\n" +
						"  verify --bundle <extension.js> --version <x.y.z> [--repo-root <dir>]\n" +
						"  render-docs [--repo-root <dir>]\n" +
						"  standalone --version <x.y.z> --output <file> [--repo-root <dir>]\n" +
						"  notes --version <x.y.z> [--repo-root <dir>]\n",
				);
				return 2;
		}
	} catch (error) {
		process.stderr.write(`error: ${error.message}\n`);
		return 1;
	}
}

if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith("cline-limits-tool.mjs")) {
	process.exitCode = main();
}

export { resolveRule, findAll, sha256, short };

