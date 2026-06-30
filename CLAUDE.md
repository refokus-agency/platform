# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`refokus-agency/platform` is **not an application**. It is a central library of GitHub Actions reusables consumed by every other repo in `refokus-agency`. There is no `package.json`, no build, no test suite, no lint. The "source code" is three reusable workflows plus one composite action:

- `.github/workflows/ci.yml` — reusable: lint + typecheck + test + build (each skipped if the caller's `package.json` lacks the script).
- `.github/workflows/deploy.yml` — reusable: Vercel deploy, parameterized by `environment: preview | stage | production`.
- `.github/workflows/release.yml` — reusable: `semantic-release` to GitHub Packages.
- `.github/actions/setup/action.yml` — composite: detects the caller's package manager from the lockfile, installs Node + pm, runs install with caching.

`examples/` holds the **atomic caller workflow files** that downstream repos copy into their own `.github/workflows/`. Naming is `<trigger>-<action>.yml` (`pr-ci.yml`, `pr-preview.yml`, `main-stage.yml`, `main-production.yml`, `production-deploy.yml`, `main-release.yml`). One file = one trigger → one action. Never group by project type; repos mix and match based on their triggers.

## Blast radius — read before editing

Most consumer repos pin `uses: refokus-agency/platform/.github/workflows/<x>.yml@v1` (the floating major tag). The `v1` tag is force-moved to every new release on the v1.x line, so anything merged to `main` and then released propagates to all consumers automatically. **A broken release on the v1.x line breaks CI/CD across every Refokus project simultaneously.** Consequences for how to work here:

- Never commit directly to `main`. PR only.
- You cannot "run" a reusable workflow locally or in this repo — it only executes when a caller invokes it. To test a change, push your branch, then temporarily point a low-stakes caller repo at `refokus-agency/platform/...@your-branch` and watch the run. `act` catches syntax errors but doesn't reliably exercise secrets or composite actions.
- Breaking changes (removing/renaming an input, changing an input default's behavior, adding a `required` input/secret, changing semantics) must use `feat!:` or a `BREAKING CHANGE:` footer so release-please cuts a new major (`v2`). Prefer additive, default-preserving changes that fit on the v1.x line. See `docs/contributing.md` for the full checklist.
- Releases are automated by [release-please](https://github.com/googleapis/release-please-action) on every push to `main`. Conventional commits open/update a release PR; merging the release PR tags the new version, creates a GitHub Release, and force-moves `@v1`. Configuration: `release-please-config.json`, `.release-please-manifest.json`, `.github/workflows/release-please.yml`. See `docs/architecture.md` → "Versioning with release-please".

## Invariants to preserve

These are load-bearing decisions. Don't undo them without reading the rationale in `docs/architecture.md`.

- **`--ignore-scripts` is the default install flag.** The composite `setup` action passes `--ignore-scripts` unless the caller sets `unsafe-install-scripts: true`. This blocks supply-chain attacks via `postinstall` and is especially important in the Dependabot flow. Keep the flag and the warning language on the `unsafe-install-scripts` input — the name is intentional.
- **Each reusable re-checks out `refokus-agency/platform` into `.platform/`** to access the local composite action path. Don't try to reference the composite via `uses: refokus-agency/platform/.github/actions/setup@...` — GitHub doesn't support that for composite actions inside a reusable workflow cleanly, which is why the secondary checkout exists. `platform-ref` input controls which ref.
- **Callers use `secrets: inherit`.** The reusables declare which secrets are `required: true` (always `GH_PAT_TOKEN`; deploy also needs `VERCEL_TOKEN`, `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID`). Don't force callers to list secrets explicitly.
- **Branch-to-environment mapping lives in the caller, not the reusable.** `deploy.yml` takes `environment:` as an input and maps it to Vercel flags inside. The caller decides which branch triggers which environment. This is why there are multiple atomic caller files instead of one monolithic per-repo file.
- **CI steps auto-skip when the caller lacks the script.** `ci.yml` probes `package.json` for `lint`/`typecheck`/`test`/`build` and skips missing ones. A library with only `test` and a site with the full kit use the same reusable unchanged.
- **Dependabot PRs fail their automatic run and are re-triggered via `workflow_dispatch` by a human reviewer.** The `pr-preview.yml` / `pr-ci.yml` examples include `workflow_dispatch:` for this. The failed→dispatched flow is the review gate; don't remove the `workflow_dispatch` triggers from caller examples. Full rationale in `docs/dependabot.md`.

## Common edits and where they go

- **Bug in a reusable's behavior** → edit the `.yml` under `.github/workflows/` or `.github/actions/setup/action.yml`. Update the matching example in `examples/` if the contract changed.
- **New input on a reusable** → add to its `inputs:` with `required: false` and a default that preserves existing behavior.
- **New caller shape** (new trigger or new trigger/action combo) → add a new file in `examples/` following `<trigger>-<action>.yml`. Do not group into subdirectories by project type.
- **Docs** → `docs/` is cross-linked markdown. `README.md` points to it.
- **Anything that only applies to one consumer repo** → does not belong here. Put it in that repo's own `.github/workflows/`.

## Governance

Two maintainers with equal merge/release authority: [@taprile314](https://github.com/taprile314) and [@beogip](https://github.com/beogip). Minor changes (bug fixes, docs, additive inputs) can be merged by either after CI passes. Architectural changes (new reusable, breaking change, composite-action contract changes) need both to agree. See `GOVERNANCE.md`.

## Conventional Commits

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `chore:`, `docs:`, `ci:`, ...). Squash-merge to `main`; the squash message is what shows up in `git log`.

**Dependency bumps surface in the changelog.** Dependabot is configured (`.github/dependabot.yml`) to commit with the `deps:` prefix, and `release-please-config.json` maps the `deps` type to a visible **Dependencies** section. Without this, Dependabot auto-detects conventional commits, emits `chore(deps)`, and release-please hides it. Note: `deps` does **not** bump the version on its own — only `feat` / `fix` / breaking do — so a dependency bump won't cut a release by itself; it rides into the next release cut by a feat/fix. If a bump genuinely changes the reusables' behavior for callers (e.g. a new runtime requirement), type it `feat:` / `fix:` so it bumps the version and propagates to `@v1` consumers promptly.
