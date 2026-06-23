---
issue_number: 30
issue_title: "feat: add release workflow variant for public npm via OIDC Trusted Publishing (v2)"
repo: "refokus-agency/platform"
labels: [enhancement, github_actions]
plan_level: "full"
depth: "medium"
branch_name: "feat/30-release-workflow-public-npm-oidc"
created_at: "2026-06-23T19:31:25Z"
---

# Implementation Plan: #30 — feat: add release workflow variant for public npm via OIDC Trusted Publishing

> **Two deliberate deviations from the issue (decided during cothinker discovery):**
> 1. **Ships on v1.x as `feat:`, NOT v2.** Every change here is additive and default-preserving (`registry` defaults to `github-packages`, new inputs optional, declaring `id-token: write` does not force callers to grant it). Nothing breaks, so release-please would not naturally cut a major and forcing one would mean inventing a non-existent breaking change. Consequence: no `docs/migrations/v1-to-v2.md`, no `v2` tag move, examples stay `@v1`. The issue title says "(v2)" and several of its ACs reference `@v2`; the ACs below are reframed to `@v1`.
> 2. **Keeps `secrets: inherit`.** The CLAUDE.md invariant ("Callers use `secrets: inherit`. Don't force callers to list secrets explicitly.") wins over the issue's "Replace `secrets: inherit` expectations with explicit secret inputs where possible." The remaining secrets (`GITHUB_TOKEN`, optional App token) are not registry-specific, so "where possible" has nothing meaningful to bind to.

## Files

| # | Action | Path | Purpose |
|---|--------|------|---------|
| 1 | modify | `.github/workflows/release.yml` | Add `registry`, `npm-version`, `provenance` inputs; add `id-token: write` to the publish job permissions; gate the GitHub-Packages `~/.npmrc` step; add a conditional npm-version guarantee step; split semantic-release into two gated steps (GH Packages with `NODE_AUTH_TOKEN`, npm without). |
| 2 | create | `examples/main-release-npm.yml` | New atomic caller example for the npm OIDC path. |
| 3 | modify | `docs/architecture.md` | Remove "Public npm publishing" from out-of-scope; document the `registry` input and OIDC requirements. |
| 4 | modify | `docs/secrets.md` | Add an OIDC section (no `NPM_TOKEN`; per-package Trusted Publisher on npmjs.org; `id-token: write`). |
| 5 | modify | `README.md` | Add a `main-release-npm.yml` row to the workflows table and a "public npm library" common shape. |

**Not touched:** `examples/main-release.yml` stays `@v1` / GitHub Packages, unchanged. `.github/actions/setup/action.yml` is not modified — the npm bump lives in `release.yml`.

## Codebase Context

- **`.github/workflows/release.yml` (current):** single `publish` job. Writes `~/.npmrc` with `@refokus-agency:registry=https://npm.pkg.github.com`, `//npm.pkg.github.com/:_authToken=${{ secrets.GITHUB_TOKEN }}`, `always-auth=true`. Runs `cycjimmy/semantic-release-action@v4` with `NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}`. `permissions:` has `contents/packages/issues/pull-requests: write` but **no `id-token`**. Re-checks out `refokus-agency/platform` into `.platform/` to reach the composite `setup` action.
- **Invariant — secondary checkout into `.platform/`** stays intact (composite action path access).
- **Invariant — `--ignore-scripts` default** in the `setup` composite — not touched.
- **Invariant — `secrets: inherit`** — kept (see deviation #2).
- **release-please:** `feat:` → minor bump on the v1.x line; the floating `v1` tag is force-moved by `.github/workflows/release-please.yml` (`git tag -f` / `push --force`). A `feat!:`/`BREAKING CHANGE:` would cut `v2` — explicitly NOT what we want here.
- **examples naming convention** (CLAUDE.md): `<trigger>-<action>.yml`, flat in `examples/`; a new caller shape = a new file.
- **`@semantic-release/npm` + OIDC:** recent versions support OIDC Trusted Publishing. `NODE_AUTH_TOKEN` must **not** be set on the npm path or npm skips OIDC and tries the (nonexistent) static token. `verifyConditions`/`npm whoami` succeed after the OIDC exchange when the Trusted Publisher config matches.
- **OIDC `job_workflow_ref`:** npm matches the Trusted Publisher config against the workflow file where `npm publish` actually runs. With a single job in `release.yml` (no nested sub-workflow), that file is `release.yml`, so consumers configure `release.yml` on npmjs.org.

## Steps

1. **Add the three new inputs** to `workflow_call.inputs` in `release.yml`: `registry` (default `'github-packages'`, values `github-packages`|`npm`), `npm-version` (default `'11.6.2'`), `provenance` (boolean, default `false`).
   **Done when:** the three inputs are declared with those defaults and no existing input changed.
2. **Add `id-token: write`** to the `publish` job's `permissions` block (static — no-op on the GH Packages path).
   **Done when:** the permissions block includes `id-token: write` alongside the current permissions.
3. **Gate the GitHub-Packages `~/.npmrc` step** with `if: inputs.registry == 'github-packages'`. On the npm path, no GH-Packages auth block is written to `~/.npmrc` (OIDC handles auth; the public registry is npm's default).
   **Done when:** the npmrc step carries the `if`; with `registry: npm` no GitHub-Packages auth block is written.
4. **Add an npm-version guarantee step** gated to `registry == 'npm'`, after `setup` and before semantic-release: read `npm -v` and install `npm@${{ inputs.npm-version }}` **only if** the installed version is below `npm-version` (semver compare via `sort -V` or equivalent).
   **Done when:** a `registry == 'npm'` step runs `npm i -g npm@<pinned>` only when the installed npm is lower than the input value.
5. **Split semantic-release into two gated steps.** GH Packages step (`if: inputs.registry == 'github-packages'`) keeps the current env including `NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}`. npm step (`if: inputs.registry == 'npm'`) sets **no** `NODE_AUTH_TOKEN` and sets `NPM_CONFIG_PROVENANCE: ${{ inputs.provenance }}`; both share the rest of the cycjimmy config.
   **Done when:** the npm step does not set `NODE_AUTH_TOKEN` and does set `NPM_CONFIG_PROVENANCE`; the GH-Packages step keeps the current env; each has its `if`.
6. **Create `examples/main-release-npm.yml`**: pin `@v1`, `with: registry: npm`, add `permissions: id-token: write` (plus the existing `contents/packages/issues/pull-requests: write`), `secrets: inherit`, triggers `push: branches: [main]` + `workflow_dispatch`.
   **Done when:** the file exists with `@v1`, `registry: npm`, `id-token: write`, `secrets: inherit`, and both triggers.
7. **Update `docs/architecture.md`:** remove "Public npm publishing" from the out-of-scope list; add a section describing the `registry` input and OIDC requirements.
   **Done when:** "Public npm publishing" no longer appears in out-of-scope and a section documents the `registry` input + OIDC.
8. **Update `docs/secrets.md`:** add a section stating the npm path needs no `NPM_TOKEN`, requires `id-token: write`, and requires a per-package Trusted Publisher on npmjs.org referencing `release.yml`.
   **Done when:** such a section exists.
9. **Update `README.md`:** add `main-release-npm.yml` to the workflows table and a "public npm library" common shape.
   **Done when:** `main-release-npm.yml` is in the table and a public-npm shape is documented.

## Interfaces

`release.yml` `workflow_call` input contract (the public interface of this change):

- `registry`: `string`, default `'github-packages'`, allowed `github-packages` | `npm`.
- `npm-version`: `string`, default `'11.6.2'` (npm bundled by LTS Node 24; hard floor 11.5.1 for OIDC).
- `provenance`: `boolean`, default `false`.
- All existing inputs unchanged: `node-version`, `package-manager`, `platform-ref`, `semantic-release-version`, `extra-plugins`, `unsafe-install-scripts`.

## Function Design

The `publish` job is the only unit; its steps (each a single concern), in order:

- `mint-token` — mint optional GitHub App token (existing).
- `checkout-caller` → `checkout-platform` — existing dual checkout into `.platform/`.
- `npmrc-ghp` — write GitHub-Packages auth block (gated `registry == 'github-packages'`).
- `setup` — composite install (existing).
- `npm-guarantee` — ensure npm ≥ `npm-version` (gated `registry == 'npm'`).
- `semantic-release-ghp` — publish to GitHub Packages with `NODE_AUTH_TOKEN` (gated `github-packages`).
- `semantic-release-npm` — publish to npm via OIDC, no `NODE_AUTH_TOKEN`, `NPM_CONFIG_PROVENANCE` from input (gated `npm`).

No step combines orchestration with lifecycle management.

## Acceptance Criteria (EARS)

- **AC-1.** When a caller invokes `release.yml` with `registry: npm`, the workflow shall publish the scoped package to `registry.npmjs.org` via OIDC Trusted Publishing.
- **AC-2.** The npm publish path shall require no `NPM_TOKEN`/static npm secret from the caller.
- **AC-3.** The publish job shall declare `id-token: write` and shall run npm CLI ≥ 11.5.1.
- **AC-4.** When `registry` is omitted or set to `github-packages`, the workflow shall publish to GitHub Packages exactly as today.
- **AC-5.** The registry target shall be selectable via the `registry` workflow_call input whose default is `github-packages`.
- **AC-6.** When publishing via npm, semantic-release shall complete version, changelog, GitHub release and npm publish without auth errors.
- **AC-7.** If `registry: npm` and the runner's npm is below `npm-version`, then the workflow shall install the pinned `npm-version` before publishing.
- **AC-8.** If `provenance` is false, then the npm publish shall not attempt provenance generation.
- **AC-9.** When `provenance` is true, the npm publish shall generate provenance.
- **AC-10.** The README and docs shall document the `registry`/`provenance` inputs and the npmjs.com Trusted Publisher configuration consumers must add.
- **AC-11.** If `registry: npm`, then `NODE_AUTH_TOKEN` shall not be set in the publish environment.

## Out of Scope

- v2 cut / `v2` tag move / `docs/migrations/v1-to-v2.md` — the change is additive and ships on v1.x (deviation from issue, decision D6).
- Replacing `secrets: inherit` with explicit secret inputs — kept per CLAUDE.md invariant (deviation, decision D4).
- Configuring the Trusted Publisher on npmjs.org for any specific package — per-consumer setup, documented not automated.
- Changing the `setup` composite action — the npm bump lives in `release.yml`.
- Provenance from private repos — the caller flips `provenance` to true only once its repo is public.

## Edge Cases + Error Handling

| # | Scenario | Source | Handling |
|---|----------|--------|----------|
| 1 | Private repo publishing a public package (navigation case) | [from issue] | `provenance` default `false`; OIDC works from private repos |
| 2 | Runner npm < 11.5.1 | [from issue] | conditional pinned npm install step (step 4) |
| 3 | `NODE_AUTH_TOKEN` present on npm path skips OIDC | [inferred] | npm path uses a separate semantic-release step with no `NODE_AUTH_TOKEN` |
| 4 | Trusted Publisher filename mismatch | [from issue] | publish runs in `release.yml`; docs tell consumers to configure `release.yml`; single job keeps the filename stable |
| 5 | First publish of a brand-new package vs subsequent | [from issue] | Trusted Publisher config must pre-exist on npmjs.org; documented |
| 6 | Caller omits `id-token: write` in their permissions | [inferred] | example includes it; docs call it out; OIDC fails loudly otherwise |
| 7 | `registry` set to an unsupported value | [inferred] | only `github-packages`|`npm` handled; documented |

## Done Criteria per Feature

| Feature | Done when (all pass) |
|---------|----------------------|
| npm OIDC publish path | AC-1, AC-2, AC-3, AC-6, AC-11 |
| Backward compatibility | AC-4, AC-5 |
| npm version guarantee | AC-3, AC-7 |
| provenance control | AC-8, AC-9 |
| docs | AC-10 |

## Risks

- `@semantic-release/npm` OIDC behavior varies by version → verify/pin `semantic-release-version`; test on a low-stakes caller before merge.
- Empty-string `NODE_AUTH_TOKEN` might still count as "set" → use two gated steps (env absent), not an empty value.
- The reusable can't run from this repo → must point a low-stakes caller at the branch, with a Trusted Publisher pre-configured on npmjs.org.
- `.cothinker/` session artifacts must not be committed → already added to `.gitignore`.
- The conditional npm install adds minor CI time → gated to the npm path and only-if-older.

## Test Strategy

- **Syntax:** `actionlint` on the changed YAML.
- **Integration:** push the branch; point a low-stakes caller repo (a test package with a Trusted Publisher configured on npmjs.org) at `refokus-agency/platform/.github/workflows/release.yml@feat/30-release-workflow-public-npm-oidc` with `registry: npm`; watch the run publish to npmjs.org.
- **Regression:** point an existing GitHub-Packages caller at the branch with default inputs; confirm it still publishes to GitHub Packages unchanged.
- **Black-box via run logs:** confirm publish target, no `NODE_AUTH_TOKEN` on the npm path, and npm version ≥ 11.5.1 printed.
