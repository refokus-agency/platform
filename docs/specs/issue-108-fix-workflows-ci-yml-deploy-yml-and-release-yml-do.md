---
issue_number: 108
issue_title: "fix(workflows): ci.yml, deploy.yml and release.yml do not forward pnpm-version, breaking every caller that pins packageManager"
repo: "refokus-agency/platform"
labels: [bug, github_actions]
plan_level: "full"
depth: "medium"
branch_name: "beogip/fix-workflows-ci.yml-deploy.yml-and-release.yml"
created_at: "2026-09-24T21:52:08Z"
---

# Implementation Plan: #108 — fix(workflows): ci.yml, deploy.yml and release.yml do not forward pnpm-version, breaking every caller that pins packageManager

Decisions from the discovery session (2026-09-24):

- Forwarding and auto-resolve ship together in ONE PR.
- Commit type is `fix:`. This is a platform bug that forces a pnpm version on consumers, so there is no major bump.
- pnpm version resolution order: explicit input, then the consumer's `package.json` (`devEngines.packageManager` / `packageManager`), then the fallback `'10'`.
- An explicit value that contradicts `package.json`, including a major-only value such as `'11'` against `pnpm@11.17.0`, is the consumer's mistake and still errors. Every example documents this.
- `bun-version` gets forwarding only. Its default stays `'latest'`.
- `node-version` auto-resolve, `bun-version` auto-resolve and a formal test mechanism are deferred to a follow-up issue.
- There will be no v2.0 issue.

## Files

| # | Action | Path | Purpose |
|---|--------|------|---------|
| 1 | create | `.github/actions/setup/resolve-pnpm-version.sh` | Resolution logic plus `--self-test` |
| 2 | modify | `.github/actions/setup/action.yml` | `pnpm-version` default becomes `''` (auto). New "Resolve pnpm version" step. Setup pnpm reads the step's output |
| 3 | modify | `.github/workflows/ci.yml` | Add `pnpm-version` / `bun-version` inputs and forward them |
| 4 | modify | `.github/workflows/deploy.yml` | Same as `ci.yml` |
| 5 | modify | `.github/workflows/release.yml` | Same as `ci.yml` |
| 6–12 | modify | `examples/{pr-ci,pr-preview,main-stage,main-production,production-deploy,main-release,main-release-npm}.yml` | Comment: `pnpm-version` is optional and auto-resolved from `package.json`. An explicit value must be EXACT |
| 13 | modify | `docs/getting-started.md` (L54-69), `docs/migration.md` (L99) | Document both inputs |
| 14 | modify | `docs/troubleshooting.md` (L70-79 area) | New entry for "Multiple versions of pnpm specified" |

## Codebase Context

- **Reading caller files inside the composite.** The "Detect package manager" step (`action.yml` L48-67) is the precedent for this.
- **Self-testing bash scripts.** `check-action-pins.sh --self-test`, run in `pin-check.yml:38`, is the precedent for this.
- **Reaching files next to `action.yml`.** `${{ github.action_path }}` resolves them from the `.platform/` checkout.
- **`pnpm/action-setup@ea17c68` (v6.1.0), `src/install-pnpm/run.ts` L154-169:**
  - `''` behaves the same as an omitted input.
  - Without an explicit version, it resolves `devEngines.packageManager` (object with `name: pnpm`), then `packageManager`, then throws "No pnpm version is specified".
  - The conflict check is an EXACT string compare: `"10.12.1" !== "10"` throws.
  - It swallows ENOENT for a missing `package.json`.
- **`oven-sh/setup-bun@0c5077e` (v2.2.0):** `'latest'` skips the `package.json` lookup. It never errors.
- **`actions/setup-node@8207627` (v7.0.0):** `node-version` is already forwarded by all three reusables. An explicit version wins over version files, with no error.
- **Invariants:**
  - New inputs are `required: false`, with defaults that preserve behavior.
  - No new third-party action, so the pin check and Dependabot coverage are untouched.
  - Callers keep `secrets: inherit`.

## Steps

1. **Write `resolve-pnpm-version.sh`.** Write `--self-test` first (TDD), then the resolution logic.
   **Done when:** `.github/actions/setup/resolve-pnpm-version.sh --self-test` exits 0, and exits non-zero when any expected value in the test table is altered.
2. **Wire the script into the composite** (`action.yml`):
   - Set the `pnpm-version` default to `''` and update the description.
   - Add a step `id: pnpm-version` with `if: steps.detect.outputs.pm == 'pnpm'`. Pass the input via `env:`, never inline `${{ }}` in `run:`. The step calls `${{ github.action_path }}/resolve-pnpm-version.sh`.
   - Change Setup pnpm to `version: ${{ steps.pnpm-version.outputs.version }}`.

   **Done when:** Setup pnpm no longer references `inputs.pnpm-version` directly, and the new step's `run:` contains no `${{ inputs.* }}`.
3. **Forward the inputs in the 3 reusables.** Add `pnpm-version` (default `''`) and `bun-version` (default `'latest'`) inputs to `ci.yml`, `deploy.yml` and `release.yml`, and forward both at each call site.
   **Done when:** all 3 `with:` blocks to `./.platform/.github/actions/setup` contain both `pnpm-version:` and `bun-version:`.
4. **Add a comment block to all 7 examples.** Document the optional `pnpm-version`, the auto-resolve behavior and the exact-version rule, and mention `bun-version`.
   **Done when:** `rg -l pnpm-version examples/` lists 7 files.
5. **Update the docs.** Document the inputs in `getting-started.md` and `migration.md`, and add the troubleshooting entry.
   **Done when:** `docs/troubleshooting.md` contains the verbatim text `Multiple versions of pnpm specified` and both fixes: remove the explicit input, or pass the exact version.
6. **Verify manually:**
   - Run `actionlint` on `action.yml` and the 3 reusables.
   - Run a temporary caller at `@<branch>` from CoThinker (`pnpm@11.17.0`).
   - Run a temporary caller at `@<branch>` from one repo with no `packageManager`.

   **Done when:** actionlint reports 0 errors, and both caller runs pass the Setup step.
7. **Draft the follow-up issue.** It covers `node-version` and `bun-version` auto-resolve, plus a test mechanism for platform (for example, running `--self-test` in CI).
   **Done when:** the issue text is drafted. Create it only after the user confirms.

## Step Coverage

| # | Step | ACs | Kind |
|---|------|-----|------|
| 1 | Write `resolve-pnpm-version.sh` | AC-2, AC-3, AC-4, AC-5, AC-8, AC-9 | criterion-driven |
| 2 | Wire the script into the composite | AC-2, AC-3, AC-4, AC-5, AC-6, AC-12 | criterion-driven |
| 3 | Forward the inputs in the 3 reusables | AC-1, AC-7 | criterion-driven |
| 4 | Add a comment block to all 7 examples | AC-10 | criterion-driven |
| 5 | Update the docs | AC-11 | criterion-driven |
| 6 | Verify manually | AC-1, AC-3, AC-5, AC-6 | criterion-driven |
| 7 | Draft the follow-up issue | none | no-criterion |

## Interfaces

- **ResolverInput**
  - `PNPM_VERSION_INPUT`: env var, may be empty.
  - Path to `package.json`: optional argument, default `$GITHUB_WORKSPACE/package.json`, which mirrors `pnpm/action-setup`.
- **ResolverOutput**
  - `version=<value>` appended to `$GITHUB_OUTPUT`. `<value>` is one of: the explicit input, `''` (let `pnpm/action-setup` read `package.json`), or `10` (fallback).
  - One log line naming the source: `input` | `devEngines` | `packageManager` | `fallback`.

## Function Design

`.github/actions/setup/resolve-pnpm-version.sh`:

- `resolve_version <input> <pkg_json>`: pure decision. Prints `<value> <source>` and has no side effects.
- `main`: reads the env, calls `resolve_version`, writes `$GITHUB_OUTPUT` and logs the source.
- `self_test`: builds temp fixture `package.json` files, asserts `resolve_version` for each case, and exits non-zero on the first mismatch.
- `DEFAULT_PNPM_VERSION=10` is defined once, at the top.

## Acceptance Criteria (EARS)

- **AC-1.** `ci.yml`, `deploy.yml` and `release.yml` shall declare optional inputs `pnpm-version` (default `''`) and `bun-version` (default `'latest'`), and forward both to the setup composite.
- **AC-2.** When the package manager is pnpm and `pnpm-version` is non-empty, the setup action shall pass that exact value to `pnpm/action-setup`.
- **AC-3.** When `pnpm-version` is empty and `package.json` `packageManager` starts with `pnpm@`, the setup action shall pass `''`, so `pnpm/action-setup` uses the `package.json` version.
- **AC-4.** When `pnpm-version` is empty and `devEngines.packageManager` is an object with `name: "pnpm"` and a `version`, the setup action shall pass `''`.
- **AC-5.** When `pnpm-version` is empty and neither field declares pnpm (missing `package.json`, no field, or another package manager), the setup action shall pass `'10'`.
- **AC-6.** If an explicit `pnpm-version` differs from the `packageManager` version (e.g. `'11'` vs `pnpm@11.17.0`), then the job shall fail with `pnpm/action-setup`'s conflict error, with no silent override.
- **AC-7.** When the package manager is bun, the setup action shall pass the caller's `bun-version` to `setup-bun` (default `'latest'`).
- **AC-8.** The resolution step shall log which source determined the version.
- **AC-9.** `resolve-pnpm-version.sh --self-test` shall cover AC-2 through AC-5, and shall exit non-zero on any mismatch.
- **AC-10.** Each of the 7 examples shall document that `pnpm-version` is optional, auto-resolved, and must be exact when set.
- **AC-11.** `docs/troubleshooting.md` shall include the "Multiple versions of pnpm specified" error with its fix.
- **AC-12.** When the package manager is not pnpm, the resolution step shall not run.

## Out of Scope

- `node-version` auto-resolve from `.nvmrc` / `.node-version` / `engines` (goes to the follow-up issue).
- `bun-version` auto-resolve. Its default stays `'latest'` (goes to the follow-up issue).
- Running `--self-test` in CI, and a general test harness for platform (goes to the follow-up issue).
- Changing the `'10'` fallback, and any v2.0 work.

## Edge Cases + Error Handling

| # | Scenario | Source | Handling |
|---|----------|--------|----------|
| 1 | `packageManager: pnpm@10.12.1` (exact ≠ `'10'`) | [inferred, verified in run.ts] | Pass `''`, which uses 10.12.1 |
| 2 | `packageManager: pnpm@11.17.0` (CoThinker) | [from issue] | Pass `''`, which uses 11.17.0 |
| 3 | Explicit `'11'` vs `pnpm@11.17.0` | [inferred] | Conflict error (AC-6). Documented in the examples |
| 4 | `packageManager: yarn@…` / `npm@…` with a pnpm lockfile | [inferred] | Not `pnpm@`, so the fallback `'10'` applies |
| 5 | `devEngines.packageManager` is an array | [inferred] | Mirror `action-setup` (object only). Falls through to `packageManager`, then the fallback |
| 6 | `package.json` missing | [inferred] | Fallback `'10'` (`action-setup` swallows ENOENT) |
| 7 | `package.json` is invalid JSON | [inferred] | Log a warning and use the fallback `'10'`. `action-setup` then fails with its own parse error |
| 8 | `jq` missing (self-hosted runner) | [inferred] | Fail the step with an explicit `::error::` |

## Done Criteria per Feature

| Feature | Done when |
|---------|-----------|
| Input forwarding | AC-1, AC-7 |
| pnpm auto-resolve | AC-2, AC-3, AC-4, AC-5, AC-6, AC-8, AC-12 |
| Self-test | AC-9 |
| Docs + examples | AC-10, AC-11 |

## Risks

| Risk | Mitigation |
|------|------------|
| `@v1` floats, so the change reaches every caller at once | Test a caller at `@<branch>` before merge. Add a release-notes line in the commit body: repos with `packageManager` now resolve pnpm from `package.json` |
| A caller with `packageManager` that "worked" by accident under `'10'` | Cannot exist: the exact compare always threw for them (verified in run.ts). No mitigation needed |
| `jq` absent on self-hosted runners | Explicit error message. GitHub-hosted runners ship `jq` |
| Script injection through the input | Pass the input via `env:`, never inline `${{ }}` in `run:` |
| No runtime files generated | Nothing to add to `.gitignore` |

## Test Strategy

- **Black-box:** `resolve-pnpm-version.sh --self-test` uses temp fixture `package.json` files, one per edge case 1–7, and asserts the value and source. It runs locally for now; CI wiring is a follow-up.
- **Lint:** run `actionlint` by hand on `action.yml` and the 3 reusables, since there is no actionlint gate in CI.
- **Live:** run temporary callers pointed at `refokus-agency/platform/...@<branch>`:
  - CoThinker (`pnpm@11.17.0`): expect a Setup pass, with the log showing the `packageManager` source.
  - One repo with no `packageManager`: expect a Setup pass, with the log showing the `fallback` source.
  - Optionally, a caller that passes `pnpm-version: '11'` against `pnpm@11.17.0`: expect the conflict error (AC-6).

## TDD Report

Tests: `resolve-pnpm-version.sh --self-test` (14 cases, committed) for resolver behavior; a local structural assertion script (yq/rg over `action.yml`, the 3 reusables, `examples/`, `docs/`; not committed, since platform has no test harness yet, see the follow-up issue) for wiring and docs. Full suite: no test framework in this repo. The repo gates `check-action-pins.sh --no-api` and `check-dependabot-coverage.sh` pass. `actionlint` reports 0 new findings (the one SC2129 in `release.yml` predates this change).

| AC | Test | Reds | Last state | Note |
|----|------|------|------------|------|
| AC-1 | wiring: `AC-1 {ci,deploy,release} declares/forwards pnpm-version`, `declares bun-version latest`, `composite pnpm-version default ''` | 1 | green | |
| AC-2 | self-test: `explicit input wins` | 1 | green | |
| AC-3 | self-test: `packageManager exact version`, `packageManager with integrity hash` | 1 | green | |
| AC-4 | self-test: `devEngines object with pnpm and version`, `devEngines wins over packageManager` | 1 | green | |
| AC-5 | self-test: `missing package.json`, `no field`, `another manager` (x2), `invalid JSON`, `devEngines array/without version`, `pnpm@ without version` | 1 | green | |
| AC-6 | self-test: `explicit input is not overridden by package.json` | 1 | green | Covers "no silent override". The conflict error itself is raised by pnpm/action-setup and needs the live caller run (Step 6, pending) |
| AC-7 | wiring: `AC-7 {ci,deploy,release} forwards bun-version`, `composite passes bun-version to setup-bun` | 1 | green | The composite already passed bun-version; the gap was in the 3 reusables |
| AC-8 | `main` run against fixtures: logs `source: input`, `source: packageManager`, `source: fallback` | 1 | green | Observed via manual invocation, not a self-test case |
| AC-9 | `--self-test` exits 0; a copy with one expected value altered exits 1 | 1 | green | |
| AC-10 | wiring: `AC-10 7 examples mention pnpm-version`, per-file `optional/auto/exact` | 1 | green | |
| AC-11 | wiring: `AC-11 error text present`, `fix: remove input`, `fix: exact version` | 1 | green | |
| AC-12 | wiring: `AC-12 resolve step gated on pnpm`, `input passed via env, not inline`, `Setup pnpm reads step output` | 1 | green | |
